"""Independent grpcio/protobuf client for the native Ruby server."""

import importlib
import json
import pathlib
import sys
import tempfile
import time

import grpc
from grpc_tools import protoc


def main():
    port, proto_path = int(sys.argv[1]), pathlib.Path(sys.argv[2])
    scenario = sys.argv[3] if len(sys.argv) > 3 else "all"
    with tempfile.TemporaryDirectory(prefix="object-framework-proto-") as directory:
        assert protoc.main(["protoc", f"-I{proto_path.parent}", f"--python_out={directory}", str(proto_path)]) == 0
        sys.path.insert(0, directory)
        messages = importlib.import_module(proto_path.stem + "_pb2")
        target = f"127.0.0.1:{port}"
        if scenario == "tls":
            credentials = grpc.ssl_channel_credentials(root_certificates=pathlib.Path(sys.argv[4]).read_bytes())
            transport = grpc.secure_channel(target, credentials, options=[("grpc.ssl_target_name_override", "localhost")])
        else:
            transport = grpc.insecure_channel(target, options=[("grpc.use_local_subchannel_pool", 1)])
        with transport as channel:
            grpc.channel_ready_future(channel).result(timeout=5)
            serialize = messages.Request.SerializeToString
            deserialize = messages.Reply.FromString

            def unary(name):
                return channel.unary_unary(f"/interop.Test/{name}", request_serializer=serialize, response_deserializer=deserialize)

            if scenario == "capacity":
                pending = unary("Slow").future(messages.Request(), timeout=3)
                time.sleep(0.1)
                with grpc.insecure_channel(target, options=[("grpc.use_local_subchannel_pool", 1)]) as other:
                    echo = other.unary_unary("/interop.Test/Echo", request_serializer=serialize, response_deserializer=deserialize)
                    try:
                        echo(messages.Request(), timeout=3)
                        raise AssertionError("Overload unexpectedly succeeded")
                    except grpc.RpcError as error:
                        assert error.code() == grpc.StatusCode.RESOURCE_EXHAUSTED, error
                pending.cancel()
                print(json.dumps({"capacity": True}))
                return

            if scenario == "transactions":
                chat = channel.stream_stream("/interop.Test/Chat", request_serializer=serialize, response_deserializer=deserialize)
                results = []
                try:
                    results = list(chat(iter(messages.Request(text=text) for text in ["a", "b"]), timeout=3))
                    raise AssertionError("Late transaction scenario unexpectedly succeeded")
                except grpc.RpcError as error:
                    assert error.code() == grpc.StatusCode.INTERNAL, error
                print(json.dumps({"transactions": True}))
                return

            first = unary("Echo")(messages.Request(text="Ada", number=7), timeout=3)
            second = unary("Echo")(messages.Request(text="Grace"), timeout=3)
            assert first.text == "Ada" and first.number == 7
            assert first.thread != second.thread and first.operation_id != second.operation_id
            large = "x" * 200_000
            assert unary("Echo")(messages.Request(text=large), timeout=5).text == large

            expand = channel.unary_stream("/interop.Test/Expand", request_serializer=serialize, response_deserializer=deserialize)
            assert [item.number for item in expand(messages.Request(number=3), timeout=3)] == [0, 1, 2]
            collect = channel.stream_unary("/interop.Test/Collect", request_serializer=serialize, response_deserializer=deserialize)
            assert collect(iter(messages.Request(number=number) for number in [1, 2, 3]), timeout=3).number == 6
            chat = channel.stream_stream("/interop.Test/Chat", request_serializer=serialize, response_deserializer=deserialize)
            assert [item.text for item in chat(iter(messages.Request(text=text) for text in ["a", "b"]), timeout=3)] == ["A", "B"]

            for method, expected in [("Missing", grpc.StatusCode.UNIMPLEMENTED), ("Fail", grpc.StatusCode.INTERNAL), ("Absent", grpc.StatusCode.NOT_FOUND)]:
                try:
                    unary(method)(messages.Request(), timeout=3)
                    raise AssertionError(f"{method} unexpectedly succeeded")
                except grpc.RpcError as error:
                    assert error.code() == expected, (method, error.code(), error.details())
                    metadata = dict(error.trailing_metadata())
                    assert "operation-id" in metadata and "error-code" in metadata
                    assert "secret" not in error.details()

            late = channel.unary_stream("/interop.Test/Late", request_serializer=serialize, response_deserializer=deserialize)
            stream = late(messages.Request(), timeout=3)
            assert next(stream).text == "before failure"
            try:
                next(stream)
                raise AssertionError("Late failure unexpectedly succeeded")
            except grpc.RpcError as error:
                assert error.code() == grpc.StatusCode.INTERNAL

            try:
                unary("Slow")(messages.Request(), timeout=0.05)
                raise AssertionError("Deadline unexpectedly succeeded")
            except grpc.RpcError as error:
                assert error.code() == grpc.StatusCode.DEADLINE_EXCEEDED
            pending = unary("Slow").future(messages.Request(), timeout=3)
            time.sleep(0.05)
            assert pending.cancel()
    print(json.dumps({"unary": True, "server_streaming": True, "client_streaming": True, "bidirectional": True, "flow_control": True, "errors": True, "deadline": True, "cancellation": True}))


if __name__ == "__main__":
    main()
