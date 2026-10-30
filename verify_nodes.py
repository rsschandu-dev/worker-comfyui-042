"""Build-time smoke test: start ComfyUI headless and prove the Qwen 2.1 nodes exist.

Runs on CPU inside the image, so a broken dependency set or a ComfyUI version
that predates Qwen 2.1 fails the build instead of failing on a live worker.
ComfyUI's own output is captured to a log and printed on failure, so a startup
crash reports its cause rather than just "exited".
"""
import json
import subprocess
import sys
import time
import urllib.request

PORT = "8199"
LOG = "/tmp/comfyui-verify.log"
REQUIRED = ["QwenImage21Cache", "TextEncodeQwenImage21", "QwenImage21"]


def get(path, timeout=5):
    return urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=timeout)


def tail(limit=4000):
    try:
        with open(LOG, "r", errors="replace") as handle:
            return handle.read()[-limit:]
    except OSError as error:
        return f"(no ComfyUI log at {LOG}: {error})"


def main():
    handle = open(LOG, "wb")
    proc = subprocess.Popen(
        [sys.executable, "main.py", "--cpu", "--port", PORT, "--disable-auto-launch"],
        stdout=handle,
        stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.time() + 420
        while time.time() < deadline:
            if proc.poll() is not None:
                return f"ComfyUI exited with code {proc.returncode} during startup.\n{tail()}"
            try:
                get("/system_stats", timeout=2)
                break
            except Exception:
                time.sleep(3)
        else:
            return f"ComfyUI did not answer /system_stats within 7 minutes.\n{tail()}"

        missing = []
        for node in REQUIRED:
            try:
                get(f"/object_info/{node}")
            except Exception:
                missing.append(node)
        if missing:
            return f"Missing Qwen 2.1 nodes: {', '.join(missing)}\n{tail()}"

        stats = json.load(get("/system_stats"))
        version = stats["system"]["comfyui_version"]
        print(f"ComfyUI in image: {version}")
        if not version.startswith("0.42"):
            return f"Expected ComfyUI 0.42.x, image reports {version}"
        print("Qwen 2.1 nodes present:", ", ".join(REQUIRED))
        return None
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
        handle.close()


if __name__ == "__main__":
    problem = main()
    if problem:
        sys.exit(problem)
