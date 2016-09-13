module ShapeInference

export
get_shape,
TensorShape

using ..TensorFlow
import TensorFlow: fillin_operation
const tf = TensorFlow

type TensorShape <: tf.AbstractTensorShape
    dims::Vector{Nullable{Int}}
    rank_unknown::Bool
end

function TensorShape(dims::Vector{Nullable{Int}})
    TensorShape(dims, false)
end

function TensorShape(dims::Vector)
    TensorShape([Nullable(Int64(_)) for _ in dims])
end

function TensorShape(dim::Void)
    TensorShape(Nullable{Int}[], true)
end

Base.length(t::TensorShape) = length(t.dims)
Base.getindex(t::TensorShape, idx) = t.dims[idx]

function Base.show(io::IO, shape::TensorShape)
    get_dim_name = x->begin
        if isnull(x)
            return "Unknown"
        else
            return string(get(x))
        end
    end
    if shape.rank_unknown
        print(io, "TensorShape[Unknown rank]")
    else
        print(io, "TensorShape[")
        print(io, join([get_dim_name(_) for _ in shape.dims], ", "))
        print(io, "]")
    end
end

function Base.broadcast!(s1::TensorShape, s2::TensorShape)
    while length(s1.dims) < length(s2.dims)
        unshift!(s1.dims, Nullable(1))
    end
    while length(s2.dims) < length(s1.dims)
        unshift!(s2.dims, Nullable(1))
    end
end


"""
Runs shape inference to return the shape of the tensor produced by the given operation.

Note this runs *statically*. Use the `shape` operation to dynamically get the shape of an operation.
"""
function get_shape(n::TensorFlow.AbstractTensor)
    t = Tensor(n)
    op = t.op
    fillin_operation(op)
    if op.op_name == "Variable"
        maybe_node = get_node_by_name("$(op.name)/Assign")
        if !isnull(maybe_node)
            node = get(maybe_node)
            fillin_operation(node)
            return get_shape(node.inputs[2])
        end
    end
    if op.op_name ∈ keys(shape_inferer)
        return shape_inferer[op.op_name](op)[t.value_index]
    else
        return TensorShape(nothing)
    end
end

function get_shape(v::Variable)
    fillin_operation(v.assign_node)
    return get_shape(v.assign_node.inputs[2])
end

function to_shape(x::AbstractArray)
    TensorShape(map(to_shape, x))
end

function to_shape(x)
    if x==-1
        return Nullable{Int}()
    else
        return Nullable(x)
    end
end

const shape_inferer = Dict{String, Function}()

function register_shape(op_name, func)
    shape_inferer[op_name] = func
end

register_shape("Placeholder", op->begin
    graph = tf.get_def_graph()
    if haskey(graph.shapes, op.name)
        return [graph.shapes[op.name]]
    else
        info("no shape for $op")
        [to_shape([_.size for _ in op.attrs["shape"].shape.dim])]
    end
end)

register_shape("Const", op->begin
    [to_shape([_.size for _ in op.attrs["value"].tensor.tensor_shape.dim])]
end)

for func in ["Log", "Exp", "Neg", "Ceil", "Floor", "Sqrt", "Square",
    "Cos", "Sin", "Tan", "Atan", "Asin", "Acos", "Tanh",
    "Cast", "Relu", "Relu6", "Elu", "Softplus", "Softsign",
    "Softmax", "Sigmoid", "Tanh", "SparseSoftmaxCrossEntropyWithLogits",
    "LogSoftmax", "LRN", "LogicalAnd", "LogicalNot", "LogicalOr", "LogicalXor"]
    register_shape(func, op->begin
        [get_shape(op.inputs[1])]
    end)
end

for func in ["Add", "Sub", "Mul", "Div", "Pow"]
    register_shape(func, op->begin
        s1 = get_shape(op.inputs[1])
        s2 = get_shape(op.inputs[2])
        broadcast!(s1, s2)
        dims = Nullable{Int}[]
        for (d1, d2) in zip(s1.dims, s2.dims)
            if isnull(d1) || isnull(d2)
                push!(dims, Nullable())
            else
                push!(dims, Nullable(max(get(d1), get(d2))))
            end
        end
        return [TensorShape(dims)]
    end)
end

register_shape("Transpose", op->begin
    [TensorShape(reverse(get_shape(op.inputs[1]).dims))]
end)

"""
`load_const(op::Operation)`

Load an op which is literally a constant or evaluated to a constant after
a small amount of constant propogation.
"""
function load_const(op)
    fillin_operation(op)
    if op.op_name == "Const"
        return Nullable(tf.load_proto(op.attrs["value"]))
    end
    if op.op_name == "Cast"
        return load_const(op.inputs[1])
    end
    if op.op_name ∈ ("Sub", "Add")
        x1 = load_const(op.inputs[1])
        x2 = load_const(op.inputs[2])
        if isnull(x1) || isnull(x2)
            return Nullable()
        else
            if op.op_name == "Sub"
                return Nullable(get(x1) - get(x2))
            elseif op.op_name == "Add"
                return Nullable(get(x1) + get(x2))
            end
        end
    end
    Nullable()
end

load_const(x::Tensor) = load_const(x.op)

register_shape("Reshape", op->begin
    n = op.inputs[2]
    op = get_op(n)
    maybe = load_const(op)
    if isnull(maybe)
        return [TensorShape(nothing)]
    else
        return get(maybe)
    end
end)

register_shape("MatMul", op->begin
    shape1 = get_shape(op.inputs[1])
    shape2 = get_shape(op.inputs[2])
    if shape1.rank_unknown || shape2.rank_unknown
        return [TensorShape(nothing)]
    end
    if "transpose_a" in keys(op.attrs)
        if op.attrs["transpose_a"].b
            reverse!(shape1.dims)
        end
    end
    if "transpose_b" in keys(op.attrs)
        if op.attrs["transpose_b"].b
            reverse!(shape2.dims)
        end
    end
    return [TensorShape([shape1.dims[1], shape2.dims[2]])]
end)

for func in ["Sum", "Prod", "Min", "Max", "All", "Any", "Mean"]
    register_shape(func, op->begin
        # TODO handle case of partial reduction
        return [TensorShape(Int[])]
    end)
end

register_shape("Shape", op->begin
    s = get_shape(op.inputs[1])
    return [TensorShape([length(s)])]
end)

register_shape("Concat", op->begin
    dim_op = op.inputs[1]
    if dim_op.op.op_name != "Const"
        return [TensorShape(nothing)]
    end
    dim = dim_op.op.attrs["value"].tensor.int_val[1] + 1
    tensors = op.inputs[2:end]
    base_shape = get_shape(tensors[1])
    base_shape.dims[dim] = Nullable(0)
    for tensor in tensors
        shape = get_shape(tensor)
        base_shape.dims[dim] = Nullable(get(base_shape.dims[dim]) + get(shape.dims[dim]))
    end
    [base_shape]
end)

register_shape("Rank", op->begin
    return [TensorShape([])]
end)

register_shape("OneHot", op->begin
    indices = op.inputs[1]
    depth = op.indices[2]
    if depth.op.op_name != "Const"
        return [TensorShape(nothing)]
    end
    depth_value = depth.attrs["value"].tensor.int_val[1]
    indices_shape = get_shape(indices)
    return [TensorShape([indices_shape.dims[1], Nullable(depth_value)])]
end)

register_shape("ExpandDims", op->begin
    x = op.inputs[1]
    x_shape = get_shape(x)
    dim = op.inputs[2]
    if dim.op.op_name != "Const"
        if x_shape.rank_unknown
            return [TensorShape(nothing)]
        else
            return [TensorShape([Nullable{Int}() for dim in 1:(length(x_shape.dims)+1)])]
        end
    end
    dim_value = load_proto(dim.op.attrs["value"])[1]
    insert!(x_shape.dims, dim_value, Nullable(1))
    return [x_shape]
end)

function conv_sizer(widths, strides, filter_shape)
    pos = ones(length(widths))
    while true
        while true
            if pos[1] + filter_shape[1] > widths[1]
                pos[1] -= strides[1]
                break
            end
            pos[1] += strides[1]
        end
        if pos[2] + filter_shape[2] > widths[2]
            pos[2] -= strides[2]
            break
        end
        pos[2] += strides[2]
    end
    return div(pos-1, strides)+1
end

register_shape("Conv2D", op->begin
    #  TODO: this is sometimes off by one when padding is VALID
    input_shape = get_shape(op.inputs[1])
    filter_shape = get_shape(op.inputs[2])
    if input_shape.rank_unknown || filter_shape.rank_unknown
        return [TensorShape(nothing)]
    end
    padding = tf.load_proto(op.attrs["padding"])
    strides = tf.load_proto(op.attrs["strides"])
    dims = Nullable{Int}[]
    push!(dims, input_shape.dims[1])
    if padding == "SAME"
        for i in 1:2
            if isnull(input_shape.dims[i+1]) || isnull(filter_shape.dims[i])
                push!(dims,  Nullable{Int}())
            else
                push!(dims, ceil(get(input_shape.dims[i+1])/strides[i+1]))
            end
        end
    elseif padding == "VALID"
        if isnull(input_shape.dims[2]) || isnull(input_shape.dims[3]) || isnull(filter_shape.dims[1]) || isnull(filter_shape.dims[2])
            for i in 1:2
                push!(dims, Nullable{Int}())
            end
        else
            new_dims = conv_sizer([get(input_shape.dims[2]), get(input_shape.dims[3])], [strides[2], strides[3]], [get(filter_shape.dims[1]), get(filter_shape.dims[2])])
            for i in 1:2
                push!(dims, Nullable(new_dims[i]))
            end
        end
    end
    push!(dims, filter_shape.dims[4])
    [TensorShape(dims)]
end)

register_shape("MaxPool", op->begin
    # TODO: also can be off by one when padding is VALID
    input_shape = get_shape(op.inputs[1])
    padding = tf.load_proto(op.attrs["padding"])
    ksize = tf.load_proto(op.attrs["ksize"])
    strides = tf.load_proto(op.attrs["strides"])
    if input_shape.rank_unknown
        return [TensorShape(nothing)]
    end
    dims = Nullable{Int}[]
    push!(dims, input_shape.dims[1])
    if padding == "SAME"
        for i in 1:2
            if isnull(input_shape.dims[i+1])
                push!(dims, Nullable{Int}())
            else
                push!(dims, ceil(get(input_shape.dims[i+1])/strides[i+1]))
            end
        end
    elseif padding == "VALID"
        if isnull(input_shape.dims[2]) || isnull(input_shape.dims[3])
            for i in 1:2
                push!(dims, Nullable{Int}())
            end
        else
            new_dims = 1+conv_sizer([get(input_shape.dims[2]), get(input_shape.dims[3])], [strides[2], strides[3]], [ksize[2], ksize[3]])
            for i in 1:2
                push!(dims, Nullable(new_dims[i]))
            end
        end
    end
    push!(dims, input_shape.dims[4])
    [TensorShape(dims)]

end)

register_shape("Split", op->begin
    num_split = op.attrs["num_split"].i
    split_dim = op.inputs[1]
    if split_dim.op.op_name != "Const"
        return [TensorShape(nothing)]
    end
    split_dim_value = split_dim.op.attrs["value"].tensor.int_val[1]
    value_shape = get_shape(op.inputs[2])
    if isnull(value_shape.dims[split_dim_value])
        split_value = Nullable{Int}()
    else
        split_value = Nullable(get(value_shape.dims[split_dim_value])/num_split)
    end
    value_shape.dims[spit_dim] = split_value
    [value_shape for i in 1:num_split]
end)

register_shape("Pack", op->begin

end)

register_shape("Slice", op->begin

end)

register_shape("Tile", op->begin
end)

register_shape("Pad", op->begin
    tensor_shape = get_shape(op.inputs[1])
    paddings = op.inputs[2]
    if paddings.op.op_name != "Const"
        return [TensorShape([Nullable{Int}() for dim in 1:length(tensor_shape.dims)])]
    end
    padding_value = tf.load_proto(padding.attrs["value"])  # TODO: this might be transposed
    for dim in 1:length(tensor_shape.dims)
        if isnull(tensor_shape.dims[dim])
            continue
        end
        tensor_shape.dims[dim] = Nullable(get(tensorshape.dims[dim]) + padding_value[dim, 1] + padding_value[dim, 2])
    end
    [tensor_shape]
end)

register_shape("Gather", op->begin
end)

register_shape("DynamicPartition", op->begin
end)

register_shape("DynamicStitch", op->begin
end)

end
