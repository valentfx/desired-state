"""Flask research UI and versioned API; collector runs in its own process."""
import argparse
from pathlib import Path

from flask import Flask, jsonify, render_template, request

from desired_state.api.session_controller import SessionController


def create_app(session_root: Path | None = None, controller=None):
    app = Flask(__name__)
    service = controller or SessionController(session_root or Path.cwd() / "sessions")

    @app.errorhandler(ValueError)
    def bad_request(error):
        return jsonify(error=str(error)), 400

    @app.errorhandler(RuntimeError)
    def conflict(error):
        return jsonify(error=str(error)), 409

    @app.get("/")
    def index():
        return render_template("index.html")

    @app.get("/api/v1/devices")
    def devices():
        return jsonify(devices=service.scan())

    @app.get("/api/v1/devices/known")
    def known_devices():
        return jsonify(devices=service.known_devices())

    @app.put("/api/v1/devices/<polar_id>/assignment")
    def assign_device(polar_id):
        body = request.get_json(silent=True) or {}
        return jsonify(service.assign_device(polar_id, body.get("participant_id")))

    @app.get("/api/v1/sessions/active")
    def active():
        return jsonify(service.status())

    @app.post("/api/v1/sessions")
    def start():
        body = request.get_json(silent=True) or {}
        assignments = body.get("assignments")
        if not isinstance(assignments, dict):
            raise ValueError("assignments must be a map of Polar ID to participant ID")
        return jsonify(service.start(assignments, body.get("seconds", 60))), 201

    @app.get("/api/v1/sessions")
    def history():
        try:
            limit = int(request.args.get("limit", "100"))
        except ValueError as exc:
            raise ValueError("limit must be an integer") from exc
        return jsonify(sessions=service.history(request.args.get("polar_id"), limit))

    @app.get("/api/v1/sessions/<session_id>/devices/<polar_id>/timeline")
    def session_timeline(session_id, polar_id):
        return jsonify(service.timeline(session_id, polar_id))

    @app.get("/api/v1/sessions/<session_id>/devices/<polar_id>/metrics")
    def session_metrics(session_id, polar_id):
        return jsonify(service.metrics(session_id, polar_id))

    @app.post("/api/v1/sessions/active/stop")
    def stop():
        return jsonify(service.stop())

    @app.get("/api/v1/sessions/<session_id>/<stream>")
    def rows(session_id, stream):
        try:
            limit = int(request.args.get("limit", "100"))
        except ValueError as exc:
            raise ValueError("limit must be an integer") from exc
        return jsonify(rows=service.rows(session_id, stream, limit))

    return app


def main():
    parser = argparse.ArgumentParser(description="Desired State local research UI")
    parser.add_argument("--host", default="127.0.0.1", help="use 0.0.0.0 for trusted LAN access")
    parser.add_argument("--port", type=int, default=5051)
    parser.add_argument("--sessions", type=Path, default=Path("sessions"))
    args = parser.parse_args()
    create_app(args.sessions).run(host=args.host, port=args.port, debug=False, use_reloader=False)


if __name__ == "__main__":
    main()
