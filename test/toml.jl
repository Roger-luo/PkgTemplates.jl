@info "testing TOML conversion"

t = Template(;user="me", dir="~/.julia/dev")
@test from_dict(Template, to_dict(t)) == t
@test toml(t) == """
user = "me"
authors = ["Roger-luo <rogerluo.rl18@gmail.com> and contributors"]
dir = "~/.julia/dev"
host = "github.com"
julia = "1.0.0"
"""

src = """
user = "me"
authors = ["Roger-luo <rogerluo.rl18@gmail.com> and contributors"]
dir = "~/.julia/dev"
host = "github.com"
julia = "1.0.0"

[CompatHelper]
[License]
[ProjectFile]
[Readme]
[SrcDir]
[TagBot]
[Tests]
"""
d = TOML.parse(src)

@test from_dict(Template, d) == Template(;user="me", dir="~/.julia/dev", plugins=[!Git])

# https://github.com/JuliaLang/TOML.jl/issues/13
@test_broken toml(t) == src
