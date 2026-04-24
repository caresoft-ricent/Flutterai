#!/usr/bin/env python3
"""Convert ONNX model to IR version 9 / opset 17 for onnxruntime 1.4.1 compatibility."""
import os
import onnx
from onnx import version_converter

model_path = 'assets/models/best.onnx'
backup_path = 'assets/models/best_ir10.onnx.bak'
output_path = 'assets/models/best.onnx'

print("Loading model...")
model = onnx.load(model_path)
print(f"Original: IR={model.ir_version}, opset={[o.version for o in model.opset_import]}")
print(f"Nodes: {len(model.graph.node)}")
ops = sorted(set(n.op_type for n in model.graph.node))
print(f"Ops: {ops}")

# Backup original
import shutil
shutil.copy2(model_path, backup_path)
print(f"Backup saved to {backup_path}")

# Try version_converter first
try:
    print("\nAttempting version_converter to opset 17...")
    converted = version_converter.convert_version(model, 17)
    print(f"Converted: IR={converted.ir_version}, opset={[o.version for o in converted.opset_import]}")
    onnx.checker.check_model(converted)
    print("Model check passed!")
    onnx.save(converted, output_path)
    print(f"Saved to {output_path}")
except Exception as e:
    print(f"version_converter failed: {e}")
    print("\nFalling back to manual IR/opset downgrade...")
    model.ir_version = 9
    for opset in model.opset_import:
        if opset.domain == '' or opset.domain == 'ai.onnx':
            opset.version = 17
    print(f"Manual: IR={model.ir_version}, opset={[o.version for o in model.opset_import]}")
    try:
        onnx.checker.check_model(model)
        print("Model check passed!")
    except Exception as e2:
        print(f"Model check warning (may still work): {e2}")
    onnx.save(model, output_path)
    print(f"Saved to {output_path}")

# Verify
m2 = onnx.load(output_path)
print(f"\nVerification: IR={m2.ir_version}, opset={[o.version for o in m2.opset_import]}, nodes={len(m2.graph.node)}")
print(f"File size: {os.path.getsize(output_path)} bytes")
