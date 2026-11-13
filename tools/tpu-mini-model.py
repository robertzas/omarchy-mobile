#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a minimal int8/uint8 TFLite FULLY_CONNECTED model for TPU bring-up.

The stock Edge TPU compiler rejects the two models already on the laptop:
`earcheek_classifier.tflite` uses `tfl.reduce_prod`, and `detect.tflite` uses
the `TFLite_Detection_PostProcess` custom op. This builds a model with one
supported op, one fixed input and a CPU reference, then checks that the LiteRT
interpreter runs it.

Run with the project's LiteRT environment:
  out/bench/venv/bin/python tools/tpu-mini-model.py --out out/tpu/mini-fc

Outputs:
  <out>.tflite       the model
  <out>-input.bin    raw input tensor bytes
  <out>-cpu.bin      raw CPU-reference output bytes
  <out>.json         shapes, dtypes, scales and the input values
"""
import argparse
import json
import struct

import flatbuffers
import numpy as np
from ai_edge_litert import schema_py_generated as schema
from ai_edge_litert.interpreter import Interpreter


def _vec_i32(builder, values):
    builder.StartVector(4, len(values), 4)
    for value in reversed(values):
        builder.PrependInt32(value)
    return builder.EndVector()


def _vec_f32(builder, values):
    builder.StartVector(4, len(values), 4)
    for value in reversed(values):
        builder.PrependFloat32(value)
    return builder.EndVector()


def _vec_i64(builder, values):
    builder.StartVector(8, len(values), 8)
    for value in reversed(values):
        builder.PrependInt64(value)
    return builder.EndVector()


def _vec_u8(builder, values):
    builder.StartVector(1, len(values), 1)
    for value in reversed(values):
        builder.PrependUint8(value)
    return builder.EndVector()


def _vec_offsets(builder, offsets):
    builder.StartVector(4, len(offsets), 4)
    for offset in reversed(offsets):
        builder.PrependUOffsetTRelative(offset)
    return builder.EndVector()


def _quant(builder, scale, zero_point):
    scale_off = _vec_f32(builder, [scale])
    zero_off = _vec_i64(builder, [zero_point])
    schema.QuantizationParametersStart(builder)
    schema.QuantizationParametersAddScale(builder, scale_off)
    schema.QuantizationParametersAddZeroPoint(builder, zero_off)
    return schema.QuantizationParametersEnd(builder)


def _tensor(builder, name, shape, tensor_type, buffer_index, quant=None):
    name_off = builder.CreateString(name)
    shape_off = _vec_i32(builder, shape)
    quant_off = _quant(builder, *quant) if quant else 0
    schema.TensorStart(builder)
    schema.TensorAddShape(builder, shape_off)
    schema.TensorAddType(builder, tensor_type)
    schema.TensorAddBuffer(builder, buffer_index)
    schema.TensorAddName(builder, name_off)
    if quant_off:
        schema.TensorAddQuantization(builder, quant_off)
    return schema.TensorEnd(builder)


def _buffer(builder, data=None):
    data_off = _vec_u8(builder, data) if data is not None else 0
    schema.BufferStart(builder)
    if data_off:
        schema.BufferAddData(builder, data_off)
    return schema.BufferEnd(builder)


def build_model(dtype_name="uint8"):
    builder = flatbuffers.Builder(4096)
    tf = schema.TensorType
    in_scale = 1.0 / 128.0
    weight_scale = 0.01
    out_scale = 1.0 / 128.0
    if dtype_name == "uint8":
        input_type = tf.UINT8
        dtype = np.uint8
    else:
        input_type = tf.INT8
        dtype = np.int8
    input_values = np.array([[1, 2, 3, 4]], dtype=dtype)
    weights = np.array([[16, -8, 4, 8]], dtype=np.int8)
    bias = np.array([0], dtype=np.int32)

    buffers = [
        _buffer(builder),
        _buffer(builder, weights.tobytes()),
        _buffer(builder, bias.tobytes()),
    ]
    tensors = [
        _tensor(builder, "input", list(input_values.shape), input_type, 0,
                (in_scale, 0)),
        _tensor(builder, "weights", list(weights.shape), tf.INT8, 1,
                (weight_scale, 0)),
        _tensor(builder, "bias", list(bias.shape), tf.INT32, 2,
                (in_scale * weight_scale, 0)),
        _tensor(builder, "output", [1, 1], input_type, 0, (out_scale, 0)),
    ]

    schema.OperatorCodeStart(builder)
    schema.OperatorCodeAddDeprecatedBuiltinCode(builder,
                                                schema.BuiltinOperator.FULLY_CONNECTED)
    schema.OperatorCodeAddBuiltinCode(builder,
                                      schema.BuiltinOperator.FULLY_CONNECTED)
    schema.OperatorCodeAddVersion(builder, 1)
    code = schema.OperatorCodeEnd(builder)

    schema.FullyConnectedOptionsStart(builder)
    schema.FullyConnectedOptionsAddFusedActivationFunction(
        builder, schema.ActivationFunctionType.NONE)
    schema.FullyConnectedOptionsAddKeepNumDims(builder, False)
    schema.FullyConnectedOptionsAddAsymmetricQuantizeInputs(builder, False)
    fc_options = schema.FullyConnectedOptionsEnd(builder)

    inputs = _vec_i32(builder, [0, 1, 2])
    outputs = _vec_i32(builder, [3])
    schema.OperatorStart(builder)
    schema.OperatorAddOpcodeIndex(builder, 0)
    schema.OperatorAddInputs(builder, inputs)
    schema.OperatorAddOutputs(builder, outputs)
    schema.OperatorAddBuiltinOptionsType(
        builder, schema.BuiltinOptions.FullyConnectedOptions)
    schema.OperatorAddBuiltinOptions(builder, fc_options)
    op = schema.OperatorEnd(builder)

    tensors_off = _vec_offsets(builder, tensors)
    sub_inputs = _vec_i32(builder, [0])
    sub_outputs = _vec_i32(builder, [3])
    ops_off = _vec_offsets(builder, [op])
    schema.SubGraphStart(builder)
    schema.SubGraphAddTensors(builder, tensors_off)
    schema.SubGraphAddInputs(builder, sub_inputs)
    schema.SubGraphAddOutputs(builder, sub_outputs)
    schema.SubGraphAddOperators(builder, ops_off)
    sub = schema.SubGraphEnd(builder)

    codes_off = _vec_offsets(builder, [code])
    subs_off = _vec_offsets(builder, [sub])
    buffers_off = _vec_offsets(builder, buffers)
    description = builder.CreateString("tpu-mini-fc")
    schema.ModelStart(builder)
    schema.ModelAddVersion(builder, 3)
    schema.ModelAddOperatorCodes(builder, codes_off)
    schema.ModelAddSubgraphs(builder, subs_off)
    schema.ModelAddDescription(builder, description)
    schema.ModelAddBuffers(builder, buffers_off)
    model = schema.ModelEnd(builder)
    builder.Finish(model, b"TFL3")
    return bytes(builder.Output()), input_values, weights, bias


def cpu_reference(model_bytes, input_values):
    interpreter = Interpreter(model_content=model_bytes)
    interpreter.allocate_tensors()
    input_detail = interpreter.get_input_details()[0]
    output_detail = interpreter.get_output_details()[0]
    interpreter.set_tensor(input_detail["index"], input_values)
    interpreter.invoke()
    return interpreter.get_tensor(output_detail["index"]), input_detail, output_detail


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default="out/tpu/mini-fc")
    parser.add_argument("--dtype", choices=("int8", "uint8"), default="uint8")
    args = parser.parse_args()

    model_bytes, input_values, weights, bias = build_model(args.dtype)
    output, input_detail, output_detail = cpu_reference(model_bytes, input_values)

    with open(args.out + ".tflite", "wb") as handle:
        handle.write(model_bytes)
    input_values.tofile(args.out + "-input.bin")
    output.tofile(args.out + "-cpu.bin")
    with open(args.out + ".json", "w", encoding="utf-8") as handle:
        json.dump({
            "model": args.out + ".tflite",
            "op": "FULLY_CONNECTED",
            "dtype_name": args.dtype,
            "input_shape": [int(x) for x in input_detail["shape"]],
            "input_dtype": str(input_detail["dtype"]),
            "output_shape": [int(x) for x in output_detail["shape"]],
            "output_dtype": str(output_detail["dtype"]),
            "input_values": input_values.flatten().tolist(),
            "weights": weights.flatten().tolist(),
            "bias": bias.flatten().tolist(),
            "cpu_output": output.flatten().tolist(),
            "model_bytes": len(model_bytes),
        }, handle, indent=2)
        handle.write("\n")

    print(f"{args.out}.tflite: {len(model_bytes)} B")
    print("input", input_detail["shape"], input_detail["dtype"],
          input_values.flatten().tolist())
    print("output", output_detail["shape"], output_detail["dtype"],
          output.flatten().tolist())


if __name__ == "__main__":
    main()
