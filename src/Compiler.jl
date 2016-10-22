module Compiler

import ..Highlights: Str, AbstractLexer, definition

type Mut{T}
    value::T
end

Base.getindex(m::Mut) = m.value
Base.setindex!(m::Mut, v) = m.value = v


immutable Token
    value::UInt
    first::Int
    last::Int
end


immutable Context
    source::Str
    pos::Mut{Int}
    length::Int
    tokens::Vector{Token}
    captures::Vector{UnitRange{Int}}
    Context(c::Context, len::Int) = new(c.source, c.pos, len, c.tokens, c.captures)
    Context(s::AbstractString) = new(s, Mut(1), endof(s), [], [])
end

isdone(ctx::Context) = ctx.pos[] > ctx.length


immutable State{s} end

state{s}(::State{s}) = s


const NULL_RANGE = 0:0
valid(r::Range) = r !== NULL_RANGE

function nullmatch(r::Regex, ctx::Context)
    local source = ctx.source
    local index = ctx.pos[]
    Base.compile(r)
    if Base.PCRE.exec(r.regex, source, index - 1, r.match_options, r.match_data)
        local range = Int(r.ovec[1] + 1):Int(r.ovec[2])
        local count = div(length(r.ovec), 2) - 1
        if count > 0
            length(ctx.captures) < count && resize!(ctx.captures, count)
            for i = 1:count
                ctx.captures[i] = r.ovec[2i + 1] == Base.PCRE.UNSET ?
                    NULL_RANGE : (Int(r.ovec[2i + 1] + 1):Int(r.ovec[2i + 2]))
            end
        end
        return range
    else
        return NULL_RANGE
    end
end
nullmatch(f::Function, ctx::Context) = f(ctx)


function update!(ctx::Context, range::Range, token::Integer)
    local pos = prevind(ctx.source, ctx.pos[] + length(range))
    if !isempty(ctx.tokens) && ctx.tokens[end].value == token
        ctx.tokens[end] = Token(token, ctx.tokens[end].first, pos)
    else
        ctx.pos[] <= pos && push!(ctx.tokens, Token(token, ctx.pos[], pos))
    end
    ctx.pos[] = nextind(ctx.source, pos)
    return ctx
end

function update!(ctx::Context, range::Range, lexer::Type, state = State{:root}())
    local pos = ctx.pos[] + length(range)
    lex!(Context(ctx, last(range)), lexer, state)
    ctx.pos[] = nextind(ctx.source, pos)
    return ctx
end

function error!(ctx::Context)
    push!(ctx.tokens, Token(hash(:error), ctx.pos[], ctx.pos[]))
    ctx.pos[] = nextind(ctx.source, pos)
    return ctx
end


lex{T <: AbstractLexer}(s::AbstractString, l::Type{T}) = lex!(Context(s), l, State{:root}())

@generated function lex!{T, s}(ctx::Context, ::Type{T}, ::State{s})
    quote
        # The main lexer loop for each state.
        while !isdone(ctx)
            $(compile_patterns(T, s))
            # When no patterns match the current `ctx` position then push an error token
            # and then move on to the next position.
            error!(ctx)
        end
        return ctx
    end
end


getrules(T, s) = get(get(definition(T), :tokens, Dict()), s, [])

function compile_patterns(T::Type, s::Symbol, rules::Vector = getrules(T, s))
    local out = Expr(:block)
    for rule in rules
        push!(out.args, compile_rule(T, s, rule))
    end
    return out
end

compile_rule(T::Type, s::Symbol, rule::Tuple) = compile_rule(T, s, rule...)

# Include the rules from state `inc` in the current state `s`.
compile_rule(T::Type, s::Symbol, inc::Symbol) = compile_patterns(T, s, getrules(T, inc))

# Inherit the rules from lexer `T` and it's state `s`.
compile_rule{T}(::Type, s::Symbol, ::Type{T}) = compile_patterns(T, s, getrules(T, s))

# Build a matcher block that tries a match and either succeeds and binds the result,
# or fails an moves on to the next block.
function compile_rule(T::Type, s::Symbol, match, bindings, target = :__none__)
    quote
        let range = nullmatch($(prepare_match(match)), ctx)
            if valid(range)
                $(prepare_bindings(bindings))
                $(prepare_target(T, s, target))
                continue # Might be skipped, depending of `prepare_target` result.
            end
        end
    end
end


# Regex matchers need to be 'left-anchored' with `\G` to work correctly.
prepare_match(r::Regex) = Regex("\\G$(r.pattern)", r.compile_options, r.match_options)
prepare_match(f::Function) = f


# Bind the matched range to the (lexer, state) tuple `tup`.
function prepare_bindings{T <: AbstractLexer}(tup::Tuple{Type{T}, Symbol})
    lexer, state = tup
    return :(update!(ctx, range, $(lexer), $(State{state}())))
end

# Bind each of a group of captured matches to each element in the tuple `t`.
function prepare_bindings(t::Tuple)
    local out = Expr(:block)
    for (nth, token) in enumerate(t)
        push!(out.args, :(update!(ctx, ctx.captures[$(nth)], $(convert_token(token)))))
    end
    return out
end

convert_token(s::Symbol) = hash(s)
convert_token(d::DataType) = d

# The common bind case: bind matched range to token `s`.
prepare_bindings(s::Symbol) = :(update!(ctx, range, $(hash(s))))


# Do nothing, pop the state, push another one on, or enter a new one entirely.
function prepare_target(T, s::Symbol, target::Symbol)
    target === :__none__ && return Expr(:block)
    target === :__pop__  && return Expr(:break)
    local state = target === :__push__ ? s : target
    return :(lex!(ctx, $(T), $(State{state}())))
end

# A tuple of states to enter must be done in 'reverse' order.
function prepare_target(T, s::Symbol, ts::Tuple)
    local out = Expr(:block)
    for t in ts
        unshift!(out.args, prepare_target(T, s, t))
    end
    return out
end

end # module
