"""Exercise HTTP/2 using the independent hyper-h2 state machine."""

import importlib
import json
import pathlib
import socket
import struct
import sys
import tempfile

import h2.config
import h2.connection
import h2.events
import h2.settings
from grpc_tools import protoc
from hyperframe.frame import WindowUpdateFrame


def main():
    port, proto_path = int(sys.argv[1]), pathlib.Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as directory:
        assert protoc.main(["protoc", f"-I{proto_path.parent}", f"--python_out={directory}", str(proto_path)]) == 0
        sys.path.insert(0, directory)
        messages = importlib.import_module(proto_path.stem + "_pb2")
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=True, header_encoding="utf-8"))
            conn.initiate_connection()
            conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 1024})
            sock.sendall(conn.data_to_send())

            def events():
                data = sock.recv(65536)
                assert data, "Connection closed unexpectedly"
                received = conn.receive_data(data)
                for event in received:
                    assert not isinstance(event, h2.events.ConnectionTerminated), event
                    if isinstance(event, h2.events.DataReceived):
                        conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                sock.sendall(conn.data_to_send())
                return received

            def headers(stream, extra=()):
                conn.send_headers(stream, [(":method", "POST"), (":scheme", "http"), (":path", "/interop.Test/Echo"), (":authority", "localhost"), ("content-type", "application/grpc"), ("te", "trailers"), *extra])
                sock.sendall(conn.data_to_send())

            def exchange(payload, extra=()):
                stream = conn.get_next_available_stream_id()
                headers(stream, extra)
                offset, body, trailers = 0, bytearray(), {}
                while offset < len(payload):
                    available = min(conn.local_flow_control_window(stream), conn.max_outbound_frame_size, len(payload) - offset)
                    if available == 0:
                        events()
                        continue
                    conn.send_data(stream, payload[offset:offset + available], end_stream=offset + available == len(payload))
                    offset += available
                    sock.sendall(conn.data_to_send())
                ended = False
                while not ended:
                    for event in events():
                        if isinstance(event, h2.events.DataReceived) and event.stream_id == stream:
                            body.extend(event.data)
                        if isinstance(event, (h2.events.TrailersReceived, h2.events.ResponseReceived)) and event.stream_id == stream:
                            trailers.update(event.headers)
                        if isinstance(event, h2.events.StreamEnded) and event.stream_id == stream:
                            ended = True
                return bytes(body), trailers

            request = messages.Request(text="x" * 200_000).SerializeToString()
            body, trailers = exchange(b"\x00" + struct.pack(">I", len(request)) + request, [("x-padding", "x" * 20_000)])
            assert trailers["grpc-status"] == "0"
            assert messages.Reply.FromString(body[5:]).text == "x" * 200_000
            _, trailers = exchange(b"\x02\x00\x00\x00\x00")
            assert trailers["grpc-status"] == "3"

            # A zero WINDOW_UPDATE on one live stream must reset that stream only.
            stream = conn.get_next_available_stream_id()
            headers(stream)
            invalid = WindowUpdateFrame(stream)
            invalid.window_increment = 0
            sock.sendall(invalid.serialize())
            reset = False
            while not reset:
                for event in events():
                    if isinstance(event, h2.events.StreamReset) and event.stream_id == stream:
                        assert event.error_code == 1
                        reset = True
            request = messages.Request(text="still open").SerializeToString()
            body, trailers = exchange(b"\x00" + struct.pack(">I", len(request)) + request)
            assert trailers["grpc-status"] == "0"
            assert messages.Reply.FromString(body[5:]).text == "still open"
    print(json.dumps({"continuation": True, "flow_control": True, "malformed_rpc": True, "stream_error_isolation": True}))


if __name__ == "__main__":
    main()
