#!/usr/bin/env python3
"""Motion test: stand, look left/right, open the mouth, step forward and back, sit, motors off.

    scripts/board-motion.py <user@host> <result-folder>

THE ROBOT MOVES: floor, 50 cm clear, no pad connected. Drives robotd over
`ssh -W` like `robotctl endurance`, checks each step against robotd's state,
writes motion.json for board-report.py. Always ends with robot.rest (never
robot.relax, which drops the robot).
"""
import json
import math
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

HEAD_YAW, MOUTH = 7, 9  # indices in duck-ipc-proto's JOINT_NAMES
DRIVING = ("stand", "walk")
SPEED = 0.3  # m/s: a slower command does not always start the gait
STEP_S = 1.5
MIN_STEP_M = 0.03
MIN_LOOK_RAD = 0.2
MIN_MOUTH_RAD = 0.3  # measured swing: 0.56
SSH = ["ssh", *os.environ.get("BOARD_SSH_OPTS", "").split()]


class Robot:
    def __init__(self, target: str):
        self.ssh = subprocess.Popen([*SSH, "-W", "/run/robotd.sock", target], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, text=True, bufsize=1)
        self.state, self.answers, self.fell, self.next_id = None, {}, False, 1
        threading.Thread(target=self._read, daemon=True).start()
        self.call("robot.subscribe", {"hz": 20})

    def _read(self) -> None:
        for line in self.ssh.stdout:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("method") == "robot.state":
                self.state = message["params"]
                self.fell |= self.state["safety"]["fallen"]
            elif "id" in message:
                self.answers[message["id"]] = message

    def send(self, method: str, params: dict, id: int | None = None) -> None:
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if id is not None:
            message["id"] = id
        self.ssh.stdin.write(json.dumps(message) + "\n")
        self.ssh.stdin.flush()

    def call(self, method: str, params: dict, timeout: float = 5.0) -> dict:
        id, self.next_id = self.next_id, self.next_id + 1
        self.send(method, params, id)
        end = time.monotonic() + timeout
        while id not in self.answers:
            if time.monotonic() > end:
                raise RuntimeError(f"{method}: no answer in {timeout:.0f} s")
            time.sleep(0.02)
        answer = self.answers.pop(id)
        if "error" in answer:
            raise RuntimeError(f"{method}: {answer['error'].get('message', answer['error'])}")
        return answer.get("result") or {}

    def move(self, vx: float, seconds: float, until=None) -> bool:
        # robotd zeroes a twist older than 500 ms: standing needs zero twists too.
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.send("robot.move", {"vx": vx, "vy": 0.0, "vyaw": 0.0})
            if until is not None and until():
                return True
            time.sleep(0.05)
        return until() if until is not None else True

    def policy(self) -> str:
        return (self.state or {}).get("policy", "")

    def pose(self) -> tuple:
        odom = self.state["odom"]
        return odom["position"][0], odom["position"][1], odom["yaw"]

    def forward(self, origin: tuple) -> float:
        """Odometry displacement along the heading at `origin`, m."""
        (x0, y0, yaw0), (x, y, _) = origin, self.pose()
        return (x - x0) * math.cos(yaw0) + (y - y0) * math.sin(yaw0)

    def motors_off(self) -> bool:
        # No torque flag in the state (safety.limp is dropped gains): torque off reads 0.0 mA.
        state = self.state or {}
        currents = state.get("currents_ma") or [1e9]
        return state.get("policy") != "rest" and max(abs(c) for c in currents) < 5.0

    def park(self) -> None:
        # Best effort: the link may be gone (Wi-Fi), and robotd stops a stale twist anyway.
        try:
            self.call("robot.stop", {}, timeout=2)
            self.move(0.0, 0.5)
            if not self.motors_off():
                self.call("robot.rest", {}, timeout=5)
        except Exception:
            pass
        try:
            self.ssh.stdin.close()
        except Exception:
            pass
        self.ssh.terminate()


def main() -> int:
    target, folder = sys.argv[1], Path(sys.argv[2])
    results = []

    def record(name: str, status: str, output: str) -> None:
        print(f"[{status}] {name}: {output}")
        results.append({"name": name, "status": status, "output": output})

    autonomous = subprocess.run([*SSH, target, "robotctl autonomous"], capture_output=True, text=True).stdout
    if "is off" not in autonomous:
        record("Nothing else drives the robot", "FAIL",
               f"autonomous mode is not off ({autonomous.strip()!r}): `robotctl autonomous off` first")
        (folder / "motion.json").write_text(json.dumps(results, indent=1))
        return 1

    print("The robot will stand up, look around, step forward and back, and sit, in 5 s. Ctrl-C cancels.")
    time.sleep(5)
    robot = Robot(target)

    def stand() -> str:
        if robot.policy() == "sit":  # enable does not rise from a latched sit
            robot.call("robot.do", {"skill": "sit_toggle"})
        else:
            robot.call("robot.enable", {"on": True, "toggle": False})
        if not robot.move(0.0, 30, until=lambda: robot.policy() in DRIVING):
            raise RuntimeError(f"policy still {robot.policy()!r} after 30 s")
        robot.move(0.0, 2.0)
        robot.fell = False  # getting up from lying raises it for ~0.3 s; falls count from here
        return f"policy {robot.policy()}"

    def look() -> str:
        yaws, seen = [], []
        for side, y in (("left", 0.5), ("right", -0.5), ("ahead", 0.0)):
            aimed = robot.call("robot.look", {"x": 1.0, "y": y, "z": 0.0})
            robot.move(0.0, 1.0)
            yaws.append(robot.state["joints"][HEAD_YAW])
            target = aimed.get("head", {}).get("head_yaw", float("nan"))
            seen.append(f"{side} {yaws[-1]:+.2f} (aimed {target:+.2f}{', clamped' if aimed.get('clamped') else ''})")
        report = "head yaw " + ", ".join(seen) + " rad"
        if yaws[0] - yaws[1] < MIN_LOOK_RAD:
            raise RuntimeError(f"{report}: did not turn")
        return report

    def mouth() -> str:
        shut = robot.state["joints"][MOUTH]
        angles = []
        for opening in (1.0, 0.0):  # a continuous intent, like the zero twist sent with it
            end = time.monotonic() + 1.0
            while time.monotonic() < end:
                robot.send("robot.mouth", {"open": opening})
                robot.send("robot.move", {"vx": 0.0, "vy": 0.0, "vyaw": 0.0})
                time.sleep(0.05)
            angles.append(robot.state["joints"][MOUTH])
        report = f"mouth {shut:+.2f}, open {angles[0]:+.2f}, closed again {angles[1]:+.2f} rad"
        if abs(angles[0] - shut) < MIN_MOUTH_RAD:
            raise RuntimeError(f"{report}: did not open")
        if abs(angles[1] - shut) > 0.1:
            raise RuntimeError(f"{report}: did not close")
        return report

    def walk(vx: float) -> str:
        origin = robot.pose()
        robot.move(vx, STEP_S / 2)
        move = robot.state.get("move", {})  # what robotd applied, mid-walk
        robot.move(vx, STEP_S / 2)
        robot.move(0.0, 1.0)
        moved = robot.forward(origin) * (1 if vx > 0 else -1)
        applied = move.get("applied", [float("nan")])[0]
        report = (f"{moved * 100:.1f} cm by odometry; robotd applied vx {applied:+.2f} m/s"
                  f"{' limited by ' + ', '.join(move['limited_by']) if move.get('limited_by') else ''}")
        if moved < MIN_STEP_M:
            raise RuntimeError(report)
        return report

    def sit() -> str:
        robot.move(0.0, 0.5)
        robot.call("robot.do", {"skill": "sit_toggle"})
        end = time.monotonic() + 15
        while robot.policy() != "sit":
            if time.monotonic() > end:
                raise RuntimeError(f"policy still {robot.policy()!r} after 15 s")
            time.sleep(0.1)
        return "policy sit"

    def rest() -> str:
        robot.call("robot.rest", {}, timeout=30)
        end = time.monotonic() + 60  # sit, rest pose, servo reboot: over 20 s
        while not robot.motors_off():
            if time.monotonic() > end:
                peak = max(abs(c) for c in robot.state.get("currents_ma") or [0])
                raise RuntimeError(f"motors still on after 60 s: policy {robot.policy()!r}, peak {peak:.0f} mA")
            time.sleep(0.1)
        return f"motors off: every current under 5 mA, policy {robot.policy()!r}"

    steps = [("Stands up", stand), ("Looks left, right, ahead", look), ("Opens and closes the mouth", mouth),
             ("Steps forward", lambda: walk(SPEED)), ("Steps back", lambda: walk(-SPEED)),
             ("Sits down", sit), ("Rests, motors off", rest)]
    stood = False
    try:
        end = time.monotonic() + 5
        while robot.state is None:
            if time.monotonic() > end:
                raise RuntimeError("no state from robotd")
            time.sleep(0.05)
        for i, (name, step) in enumerate(steps):
            try:
                record(name, "PASS", step())
            except Exception as why:
                record(name, "FAIL", str(why))
            stood = stood or (i == 0 and results[-1]["status"] == "PASS")
            # Stop only on a fall or a failed stand; a short walk does not stop the rest.
            if robot.fell or not stood:
                for later, _ in steps[i + 1:]:
                    record(later, "SKIP", f"not run after: {name.lower()}")
                break
    except KeyboardInterrupt:
        record("Motion test", "FAIL", "cancelled")
    except Exception as why:
        record("Motion test", "FAIL", str(why))
    finally:
        robot.park()
    if not stood:
        record("Never fell once standing", "SKIP", "never stood")
    else:
        record("Never fell once standing", "FAIL" if robot.fell else "PASS",
               "fallen flag seen" if robot.fell else "upright throughout")

    (folder / "motion.json").write_text(json.dumps(results, indent=1))
    return 1 if any(r["status"] == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
