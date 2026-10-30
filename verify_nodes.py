"""Build-time smoke test: start ComfyUI headless and prove the Qwen 2.1 nodes exist.

Runs on CPU inside the image, so a broken dependency set or a ComfyUI version
that predates Qwen 2.1 fails the build instead of failing on a live worker.
"""
import json
import subprocess
import sys
import time
import urllib.request

PORT = "8199"
REQUIRED = ["QwenImage21Cache", "TextEncodeQwenImage21", "QwenImage21"]


def get(path, timeout=5):
    return urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=timeout)


def main():
    proc = subprocess.Popen(
        [sys.executable, "main.py", "--cpu", "--port", PORT, "--disable-auto-launch"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.time() + 420
        while time.time() < deadline:
            try:
                get("/system_stats", timeout=2)
                break
            except Exception:
                if proc.poll() is not None:
                    return "ComfyUI exited during startup; see the build log."
                time.sleep(3)
        else:
            return "ComfyUI did not answer /system_stats within 7 minutes."

        missing = []
        for node in REQUIRED:
            try:
                get(f"/object_info/{node}")
            except Exception:
                missing.append(node)
        if missing:
            return f"Missing Qwen 2.1 nodes: {', '.join(missing)}"

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


if __name__ == "__main__":
    problem = main()
    if problem:
        sys.exit(problem)
