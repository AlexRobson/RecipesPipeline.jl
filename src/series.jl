# # Series handling

const FuncOrFuncs{F} = Union{F, Vector{F}, Matrix{F}}
const MaybeNumber = Union{Number, Missing}
const MaybeString = Union{AbstractString, Missing}
const DataPoint = Union{MaybeNumber, MaybeString}

_prepare_series_data(x) = error("Cannot convert $(typeof(x)) to series data for plotting")
_prepare_series_data(::Nothing) = nothing
_prepare_series_data(t::Tuple{T, T}) where {T <: Number} = t
_prepare_series_data(f::Function) = f
_prepare_series_data(ar::AbstractRange{<:Number}) = ar
function _prepare_series_data(a::AbstractArray{<:MaybeNumber})
    f = isimmutable(a) ? replace : replace!
    a = f(x -> ismissing(x) || isinf(x) ? NaN : x, map(float, a))
end
_prepare_series_data(a::AbstractArray{<:Missing}) = fill(NaN, axes(a))
_prepare_series_data(a::AbstractArray{<:MaybeString}) =
    replace(x -> ismissing(x) ? "" : x, a)
_prepare_series_data(s::Surface{<:AMat{<:MaybeNumber}}) =
    Surface(_prepare_series_data(s.surf))
_prepare_series_data(s::Surface) = s  # non-numeric Surface, such as an image
_prepare_series_data(v::Volume) =
    Volume(_prepare_series_data(v.v), v.x_extents, v.y_extents, v.z_extents)

# default: assume x represents a single series
_series_data_vector(x, plotattributes) = [_prepare_series_data(x)]

# fixed number of blank series
_series_data_vector(n::Integer, plotattributes) = [zeros(0) for i in 1:n]

# vector of data points is a single series
_series_data_vector(v::AVec{<:DataPoint}, plotattributes) = [_prepare_series_data(v)]

# list of things (maybe other vectors, functions, or something else)
function _series_data_vector(v::AVec, plotattributes)
    if all(x -> x isa MaybeNumber, v)
        _series_data_vector(Vector{MaybeNumber}(v), plotattributes)
    elseif all(x -> x isa MaybeString, v)
        _series_data_vector(Vector{MaybeString}(v), plotattributes)
    else
        vcat((_series_data_vector(vi, plotattributes) for vi in v)...)
    end
end

# Matrix is split into columns
function _series_data_vector(v::AMat{<:DataPoint}, plotattributes)
    if is3d(plotattributes)
        [_prepare_series_data(Surface(v))]
    else
        [_prepare_series_data(v[:, i]) for i in axes(v, 2)]
    end
end

# --------------------------------------------------------------------
# Fillranges & ribbons


_process_fillrange(range::Number, plotattributes) = [range]
_process_fillrange(range, plotattributes) = _series_data_vector(range, plotattributes)

_process_ribbon(ribbon::Number, plotattributes) = [ribbon]
_process_ribbon(ribbon, plotattributes) = _series_data_vector(ribbon, plotattributes)
# ribbon as a tuple: (lower_ribbons, upper_ribbons)
_process_ribbon(ribbon::Tuple{S, T}, plotattributes) where {S, T} = collect(zip(
    _series_data_vector(ribbon[1], plotattributes),
    _series_data_vector(ribbon[2], plotattributes),
))


# --------------------------------------------------------------------

_compute_x(x::Nothing, y::Nothing, z) = axes(z, 1)
_compute_x(x::Nothing, y, z) = axes(y, 1)
_compute_x(x::Function, y, z) = map(x, y)
_compute_x(x, y, z) = x

_compute_y(x::Nothing, y::Nothing, z) = axes(z, 2)
_compute_y(x, y::Function, z) = map(y, x)
_compute_y(x, y, z) = y

_compute_z(x, y, z::Function) = map(z, x, y)
_compute_z(x, y, z::AbstractMatrix) = Surface(z)
_compute_z(x, y, z::Nothing) = nothing
_compute_z(x, y, z) = z

_nobigs(v::AVec{BigFloat}) = map(Float64, v)
_nobigs(v::AVec{BigInt}) = map(Int64, v)
_nobigs(v) = v

@noinline function _compute_xyz(x, y, z)
    x = _compute_x(x, y, z)
    y = _compute_y(x, y, z)
    z = _compute_z(x, y, z)
    if !isnothing(x) && isnothing(z)
        n = size(x,1)
        !isnothing(y) && size(y,1) != n && error("Expects $n elements in each col of y, found $(size(y,1)).")
    end
    _nobigs(x), _nobigs(y), _nobigs(z)
end

# not allowed
_compute_xyz(x::Nothing, y::FuncOrFuncs{F}, z) where {F <: Function} =
    error("If you want to plot the function `$y`, you need to define the x values!")
_compute_xyz(x::Nothing, y::Nothing, z::FuncOrFuncs{F}) where {F <: Function} =
    error("If you want to plot the function `$z`, you need to define x and y values!")
_compute_xyz(x::Nothing, y::Nothing, z::Nothing) = error("x/y/z are all nothing!")

# --------------------------------------------------------------------


# we are going to build recipes to do the processing and splitting of the args

# --------------------------------------------------------------------
# The catch-all SliceIt recipe
# --------------------------------------------------------------------

# ensure we dispatch to the slicer
struct SliceIt end

# TODO: Should ribbon and fillrange be handled by the plotting package?

# The `SliceIt` recipe finishes user and type recipe processing.
# It splits processed data into individual series data, stores in copied `plotattributes`
# for each series and returns no arguments.
@recipe function f(::Type{SliceIt}, x, y, z)
    @nospecialize

    # handle data with formatting attached
    if typeof(x) <: Formatted
        xformatter := x.formatter
        x = x.data
    end
    if typeof(y) <: Formatted
        yformatter := y.formatter
        y = y.data
    end
    if typeof(z) <: Formatted
        zformatter := z.formatter
        z = z.data
    end

    xs = _series_data_vector(x, plotattributes)
    ys = _series_data_vector(y, plotattributes)
    zs = _series_data_vector(z, plotattributes)

    fr = pop!(plotattributes, :fillrange, nothing)
    fillranges = _process_fillrange(fr, plotattributes)
    mf = length(fillranges)

    rib = pop!(plotattributes, :ribbon, nothing)
    ribbons = _process_ribbon(rib, plotattributes)
    mr = length(ribbons)

    mx = length(xs)
    my = length(ys)
    mz = length(zs)
    if mx > 0 && my > 0 && mz > 0
        for i in 1:max(mx, my, mz)
            # add a new series
            di = copy(plotattributes)
            xi, yi, zi = xs[mod1(i, mx)], ys[mod1(i, my)], zs[mod1(i, mz)]
            di[:x], di[:y], di[:z] = _compute_xyz(xi, yi, zi)

            # handle fillrange
            fr = fillranges[mod1(i, mf)]
            di[:fillrange] = isa(fr, Function) ? map(fr, di[:x]) : fr

            # handle ribbons
            rib = ribbons[mod1(i, mr)]
            di[:ribbon] = isa(rib, Function) ? map(rib, di[:x]) : rib

            push!(series_list, RecipeData(di, ()))
        end
    end
    nothing  # don't add a series for the main block
end
