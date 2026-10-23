"""Cross-check every proto3 scalar against Google's generated Python codec."""

import base64
import importlib
import json
import pathlib
import sys
import tempfile

from grpc_tools import protoc


def main():
    path, encoded = pathlib.Path(sys.argv[1]), base64.b64decode(sys.argv[2])
    with tempfile.TemporaryDirectory() as directory:
        assert protoc.main(["protoc", f"-I{path.parent}", f"--python_out={directory}", str(path)]) == 0
        sys.path.insert(0, directory)
        module = importlib.import_module(path.stem + "_pb2")
        message = module.Everything(
            int32_value=-2**31, int64_value=-2**63, uint32_value=2**32-1,
            uint64_value=2**64-1, sint32_value=-123, sint64_value=-456,
            fixed32_value=2**32-1, fixed64_value=2**64-1,
            sfixed32_value=-123, sfixed64_value=-456, float_value=1.5,
            double_value=-2.5, bool_value=True, string_value="Hello λ",
            bytes_value=b"\x00\xff", state=1, values=[-1, 0, 1],
            nested=module.Nested(name="Ada"),
        )
        assert module.Everything.FromString(encoded) == message
        print(json.dumps({"encoded": base64.b64encode(message.SerializeToString()).decode()}))


if __name__ == "__main__":
    main()
