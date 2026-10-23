"""Confirm an order with grpcio and a contract exported by the Ruby server."""

import importlib
import pathlib
import sys
import tempfile

import grpc
from grpc_tools import protoc

port, contract, order_id = int(sys.argv[1]), pathlib.Path(sys.argv[2]).resolve(), sys.argv[3]
with tempfile.TemporaryDirectory() as directory:
    if protoc.main(["protoc", f"-I{contract.parent}", f"--python_out={directory}", str(contract)]) != 0:
        raise RuntimeError("Contract compilation failed")
    sys.path.insert(0, directory)
    messages = importlib.import_module(contract.stem + "_pb2")
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        confirm = channel.unary_unary(
            "/orders.Orders/ConfirmOrder",
            request_serializer=messages.ConfirmOrderRequest.SerializeToString,
            response_deserializer=messages.OrderConfirmation.FromString,
        )
        result = confirm(messages.ConfirmOrderRequest(order_id=order_id), timeout=3)
        print(f"{result.id}: {result.state}")
