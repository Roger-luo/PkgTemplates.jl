default_user() = LibGit2.getconfig("github.user", "")
default_version() = VersionNumber(VERSION.major)
default_plugins() = [
    CompatHelper(),
    Git(),
    License(),
    ProjectFile(),
    Readme(),
    SrcDir(),
    TagBot(),
    Tests(),
]

function default_authors()
    name = LibGit2.getconfig("user.name", "")
    isempty(name) && return "contributors"
    email = LibGit2.getconfig("user.email", "")
    authors = isempty(email) ? name : "$name <$email>"
    return ["$authors and contributors"]
end

struct MissingUserException{T} <: Exception end
function Base.showerror(io::IO, ::MissingUserException{T}) where T
    s = """$(nameof(T)): Git hosting service username is required, set one with keyword `user="<username>"`"""
    print(io, s)
end

"""
    Template(; kwargs...)

A configuration used to generate packages.

## Keyword Arguments

### User Options
- `user::AbstractString="$(default_user())"`: GitHub (or other code hosting service) username.
  The default value comes from the global Git config (`github.user`).
  If no value is obtained, many plugins that use this value will not work.
- `authors::Union{AbstractString, Vector{<:AbstractString}}="$(default_authors())"`: Package authors.
  Like `user`, it takes its default value from the global Git config
  (`user.name` and `user.email`).

### Package Options
- `dir::AbstractString="$(contractuser(Pkg.devdir()))"`: Directory to place packages in.
- `host::AbstractString="github.com"`: URL to the code hosting service where packages will reside.
- `julia::VersionNumber=$(repr(default_version()))`: Minimum allowed Julia version.

### Template Plugins
- `plugins::Vector{<:Plugin}=Plugin[]`: A list of [`Plugin`](@ref)s used by the template.
  The default plugins are [`ProjectFile`](@ref), [`SrcDir`](@ref), [`Tests`](@ref),
  [`Readme`](@ref), [`License`](@ref), [`Git`](@ref), [`CompatHelper`](@ref), and
  [`TagBot`](@ref).
  To disable a default plugin, pass in the negated type: `!PluginType`.
  To override a default plugin instead of disabling it, pass in your own instance.

### Interactive Mode
- `interactive::Bool=false`: In addition to specifying the template options with keywords,
  you can also build up a template by following a set of prompts.
  To create a template interactively, set this keyword to `true`.
  See also the similar [`generate`](@ref) function.

---

To create a package from a `Template`, use the following syntax:

```julia
julia> t = Template();

julia> t("PkgName")
```
"""
@option struct Template
    user::String = default_user()
    authors::Vector{String} = default_authors()
    dir::String = contractuser(Pkg.devdir())
    host::String = "github.com"
    julia::VersionNumber = default_version()
    plugins::Vector{<:Plugin} = default_plugins()

    function Template(user, authors, dir, host, julia, plugins)
        host = replace(host, r".*://" => "")
        authors isa Vector || (authors = map(strip, split(authors, ",")))
        plugins = collect(Any, plugins)
        disabled = map(d -> first(typeof(d).parameters), filter(p -> p isa Disabled, plugins))
        filter!(p -> p isa Plugin, plugins)
        append!(plugins, filter(p -> !(typeof(p) in disabled), default_plugins()))
        plugins = Vector{Plugin}(sort(unique(typeof, plugins); by=string))

        if isempty(user)
            foreach(plugins) do p
                needs_username(p) && throw(MissingUserException{typeof(p)}())
            end
        end

        t = new(user, authors, normpath(dir), host, julia, plugins)
        foreach(p -> validate(p, t), plugins)
        return t
    end

    function Template(; interactive::Bool=false, kwargs...)
        interactive && return PkgTemplates.interactive(Template; kwargs...)
        Configurations.validate_keywords(Template; kwargs...)
        return Configurations.create(Template; kwargs...)
    end
end

function Configurations.dictionalize(t::Template)
    d = OrderedDict{String, Any}(
        "user" => t.user,
        "authors" => t.authors,
        "dir" => t.dir,
        "host" => t.host,
        "julia" => t.julia,
    )

    # NOTE: we use emptry field to represent
    # using a default value for plugin
    # and all plugins must be listed in the TOML
    # file.
    for plugin in t.plugins
        P = typeof(plugin)
        alias = Configurations.alias(P)
        name = alias === nothing ? string(nameof(P)) : alias
        plugin_dict = Configurations.dictionalize(plugin)
        d[name] = plugin_dict
    end
    return d
end

function get_template_field(d::AbstractDict{String}, name::Symbol)
    return get(d, string(name), field_default(Template, name))
end

function collect_plugins!(plugins::Vector{Any}, ::Type{T}, d::AbstractDict{String}) where T
    for each in subtypes(T)
        if isabstracttype(each)
            collect_plugins!(plugins, each, d)
            continue
        end
        
        alias = Configurations.alias(each)
        name = alias === nothing ? string(nameof(each)) : alias
        if name in keys(d)
            push!(plugins, from_dict(each, d[name]))
        end
    end

    # treat missing default plugins as disabled
    for each in default_plugins()
        plugin_t = typeof(each)
        idx = findfirst(plugins) do x
            typeof(x) == plugin_t
        end

        if idx === nothing
            push!(plugins, !plugin_t)
        end
    end
    
    return plugins
end

function collect_plugins(d::AbstractDict{String})
    return collect_plugins!([], Plugin, d)
end

function Configurations.from_dict_validate(::Type{Template}, d::AbstractDict{String})
    user = get_template_field(d, :user)
    authors = get_template_field(d, :authors)
    dir = get_template_field(d, :dir)
    host = get_template_field(d, :host)

    version = get_template_field(d, :julia)
    julia =  version isa VersionNumber ? version : VersionNumber(version)
    plugins = collect_plugins(d)
    return Template(user, authors, dir, host, julia, plugins)
end

"""
    (::Template)(pkg::AbstractString)

Generate a package named `pkg` from a [`Template`](@ref).
"""
function (t::Template)(pkg::AbstractString)
    endswith(pkg, ".jl") && (pkg = pkg[1:end-3])
    pkg_dir = joinpath(abspath(expanduser(t.dir)), pkg)
    ispath(pkg_dir) && throw(ArgumentError("$pkg_dir already exists"))
    mkpath(pkg_dir)

    try
        foreach((prehook, hook, posthook)) do h
            @info "Running $(nameof(h))s"
            foreach(sort(t.plugins; by=p -> priority(p, h), rev=true)) do p
                h(p, t, pkg_dir)
            end
        end
    catch
        rm(pkg_dir; recursive=true, force=true)
        rethrow()
    end

    @info "New package is at $pkg_dir"
end

# Does the template have a plugin that satisfies some predicate?
hasplugin(t::Template, f::Function) = any(f, t.plugins)
hasplugin(t::Template, ::Type{T}) where T <: Plugin = hasplugin(t, p -> p isa T)

"""
    getplugin(t::Template, ::Type{T<:Plugin}) -> Union{T, Nothing}

Get the plugin of type `T` from the template `t`, if it's present.
"""
function getplugin(t::Template, ::Type{T}) where T <: Plugin
    i = findfirst(p -> p isa T, t.plugins)
    return i === nothing ? nothing : t.plugins[i]
end

function interactive(::Type{Template}; kwargs...)
    # If the user supplied any keywords themselves, don't prompt for them.
    kwargs = Dict{Symbol, Any}(kwargs)
    options = [:user, :authors, :dir, :host, :julia, :plugins]
    customizable = setdiff(options, keys(kwargs))

    # Make sure we don't try to show a menu with < 2 options.
    isempty(customizable) && return Template(; kwargs...)
    just_one = length(customizable) == 1
    just_one && push(customizable, "None")

    try
        println("Template keywords to customize:")
        menu = MultiSelectMenu(map(string, customizable); pagesize=length(customizable))
        customize = customizable[sort!(collect(request(menu)))]
        just_one && lastindex(customizable) in customize && return Template(; kwargs...)

        # Prompt for each keyword.
        foreach(customize) do k
            kwargs[k] = prompt(Template, fieldtype(Template, k), k)
        end

        while true
            try
                return Template(; kwargs...)
            catch e
                e isa MissingUserException || rethrow()
                kwargs[:user] = prompt(Template, String, :user)
            end
        end
    catch e
        e isa InterruptException || rethrow()
        println()
        @info "Cancelled"
        return nothing
    end
end

prompt(::Type{Template}, ::Type, ::Val{:pkg}) = Base.prompt("Package name")

function prompt(::Type{Template}, ::Type, ::Val{:user})
    return if isempty(default_user())
        input = Base.prompt("Enter value for 'user' (String, required)")
        input === nothing && throw(InterruptException())
        return input
    else
        fallback_prompt(String, :user)
    end
end

function prompt(::Type{Template}, ::Type, ::Val{:host})
    hosts = ["github.com", "gitlab.com", "bitbucket.org", "Other"]
    menu = RadioMenu(hosts; pagesize=length(hosts))
    println("Select Git repository hosting service:")
    idx = request(menu)
    return if idx == lastindex(hosts)
        fallback_prompt(String, :host)
    else
        hosts[idx]
    end
end

function prompt(::Type{Template}, ::Type, ::Val{:julia})
    versions = map(format_version, VersionNumber.(1, 0:VERSION.minor))
    push!(versions, "Other")
    menu = RadioMenu(map(string, versions); pagesize=length(versions))
    println("Select minimum Julia version:")
    idx = request(menu)
    return if idx == lastindex(versions)
        fallback_prompt(VersionNumber, :julia)
    else
        VersionNumber(versions[idx])
    end
end

const CR = "\r"
const DOWN = "\eOB"

function prompt(::Type{Template}, ::Type, ::Val{:plugins})
    defaults = map(typeof, default_plugins())
    ndefaults = length(defaults)
    # Put the defaults first.
    options = unique!([defaults; concretes(Plugin)])
    menu = MultiSelectMenu(map(T -> string(nameof(T)), options); pagesize=length(options))
    println("Select plugins:")
    # Pre-select the default plugins and move the cursor to the first non-default.
    # To make this better, we need julia#30043.
    print(stdin.buffer, (CR * DOWN)^ndefaults)
    types = sort!(collect(request(menu)))
    plugins = Vector{Any}(map(interactive, options[types]))
    # Find any defaults that were disabled.
    foreach(i -> i in types || push!(plugins, !defaults[i]), 1:ndefaults)
    return plugins
end

# Call the default prompt method even if a specialized one exists.
fallback_prompt(T::Type, name::Symbol) = prompt(Template, T, Val(name), nothing)

function default_branch(t::Template)
    git = getplugin(t, Git)
    return git === nothing ? nothing : git.branch
end
