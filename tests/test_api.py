import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from desired_state.api.app import create_app
from desired_state.api.device_registry import DeviceRegistry


class FakeController:
    def scan(self):
        return [{"polar_id": "E9E53B2C", "name": "Polar H10 E9E53B2C"}]

    def start(self, assignments, seconds):
        if not assignments:
            raise ValueError("assignments required")
        return {"session_id": "example", "running": True}

    def known_devices(self):
        return []

    def assign_device(self, polar_id, participant_id):
        return {"polar_id": polar_id, "participant_id": participant_id}

    def status(self):
        return {"session_id": None, "running": False, "return_code": None, "log_tail": ""}

    def stop(self):
        raise RuntimeError("No active session")

    def rows(self, session_id, stream, limit):
        return [{"session_id": session_id, "stream": stream}]


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.client = create_app(controller=FakeController()).test_client()

    def test_page_and_scan(self):
        self.assertEqual(self.client.get("/").status_code, 200)
        self.assertEqual(self.client.get("/api/v1/devices").json["devices"][0]["polar_id"], "E9E53B2C")
        self.assertEqual(self.client.get("/api/v1/devices/known").json["devices"], [])
        response = self.client.put("/api/v1/devices/E9E53B2C/assignment", json={"participant_id": "person_2"})
        self.assertEqual(response.json["participant_id"], "person_2")

    def test_start_validation_and_conflict(self):
        self.assertEqual(self.client.post("/api/v1/sessions", json={"assignments": {}}).status_code, 400)
        response = self.client.post("/api/v1/sessions", json={"assignments": {"E9E53B2C": "person_1"}})
        self.assertEqual((response.status_code, response.json["session_id"]), (201, "example"))
        self.assertEqual(self.client.post("/api/v1/sessions/active/stop").status_code, 409)

    def test_recent_rows(self):
        response = self.client.get("/api/v1/sessions/example/rr?limit=5")
        self.assertEqual(response.json["rows"][0]["stream"], "rr")
        self.assertEqual(self.client.get("/api/v1/sessions/example/rr?limit=oops").status_code, 400)


if __name__ == "__main__":
    unittest.main()


class RegistryTests(unittest.TestCase):
    def test_assignment_survives_restart_and_address_update(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "devices.json"
            first = DeviceRegistry(path)
            first.observe([{"polar_id": "E9E53B2C", "name": "Polar H10 E9E53B2C", "address": "old"}])
            first.assign("E9E53B2C", "person_1")
            next_run = DeviceRegistry(path)
            next_run.observe([{"polar_id": "E9E53B2C", "name": "Polar H10 E9E53B2C", "address": "new"}])
            self.assertEqual(next_run.list()[0]["participant_id"], "person_1")
            self.assertEqual(next_run.list()[0]["address"], "new")
            next_run.assign("E9E53B2C", "person_2")
            self.assertEqual(DeviceRegistry(path).list()[0]["participant_id"], "person_2")
