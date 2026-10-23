#!/usr/bin/env python3
import os
import sys
import argparse
import subprocess
import shlex
from pathlib import Path


def find_project_root() -> Path:
    """Dynamically locates the root directory containing 'src'."""
    script_dir = Path(__file__).resolve().parent
    for p in [script_dir] + list(script_dir.parents):
        if (p / "src").is_dir():
            return p

    cwd = Path.cwd().resolve()
    for p in [cwd] + list(cwd.parents):
        if (p / "src").is_dir():
            return p

    print("Error: Could not locate project root directory containing 'src/'.")
    sys.exit(1)


PROJECT_DIR = find_project_root()
SRC_DIR = PROJECT_DIR / "src"
TCL_DIR = PROJECT_DIR / "tcl"
LOGS_DIR = PROJECT_DIR / "logs"


def collect_hdl_sources():
    """Recursively collects all synthesizable Verilog/SystemVerilog files relative to project root."""
    sources = []
    for ext in ("*.v", "*.sv"):
        for p in SRC_DIR.rglob(ext):
            rel_p = p.relative_to(PROJECT_DIR).as_posix()
            sources.append(rel_p)
    return sources


def parse_args():
    parser = argparse.ArgumentParser(description="Run Synopsys Design Compiler Synthesis Flow")
    parser.add_argument("--top", default="r22_fft_top", help="Top module name for synthesis")
    parser.add_argument("--clk", type=float, default=10.0, help="Clock target period in ns")
    parser.add_argument("--step", type=int, default=26, help="FFT size parameter")
    parser.add_argument("--remote", default="vlsi", help="SSH remote host target")
    parser.add_argument("--remote-path", default="labs/fft", help="Remote project directory path")
    parser.add_argument("--local", action="store_true", help="Run locally instead of over SSH")
    return parser.parse_args()


def run_and_tee(cmd, log_file_path, cwd=None):
    """Executes a command, streams output live to terminal, and writes to log file."""
    with open(log_file_path, "w") as log_file:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd=cwd
        )
        for line in iter(process.stdout.readline, ""):
            sys.stdout.write(line)
            sys.stdout.flush()
            log_file.write(line)
            log_file.flush()

        process.wait()
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, cmd)


def main():
    args = parse_args()

    top_module = args.top
    clk_period = args.clk
    step = args.step
    remote_host = args.remote
    remote_path = args.remote_path
    proj_root = PROJECT_DIR.as_posix()

    LOGS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"--- [Design Compiler] Top Module : {top_module} ---")
    print(f"--- [Design Compiler] Clock Target: {clk_period} ns ---")
    print(f"--- [Design Compiler] Execution Target: {'Local' if args.local else f'Remote ({remote_host})'} ---")

    hdl_files = collect_hdl_sources()
    if not hdl_files:
        print("Error: No HDL files (.v, .sv) found under src/")
        sys.exit(1)

    file_list_str = " ".join(hdl_files)

    # 1. Sync source files via rsync
    if not args.local:
        print(f"\n[1/3] Syncing source to {remote_host}...")
        rsync_cmd = [
            "rsync", "-avz", "--delete",
            "--ignore-errors",
            "--exclude", ".git/",
            "--exclude", "sim/gen/",
            "--exclude", "syn/gen/",
            "--exclude", ".nfs*",
            f"{proj_root}/", f"{remote_host}:{remote_path}/"
        ]
        try:
            subprocess.run(rsync_cmd, check=True)
            print("Source sync complete.")
        except subprocess.CalledProcessError as e:
            print(f"Error: rsync failed with return code {e.returncode}.")
            sys.exit(1)

    # 2. Build synthesis command
    dc_tcl_cmd = (
        f"set DESIGN_NAME {top_module}; "
        f"set STEP {step}; "
        f"set CLK_PERIOD {clk_period}; "
        f"analyze -format sverilog -define {{SYNTHESIS}} [list {file_list_str}]; "
        f"source tcl/dc_flow.tcl"
    )

    log_file = LOGS_DIR / f"{top_module}_dc.log"

    print("\n[2/3] Running Design Compiler Synthesis...\n")
    if args.local:
        exec_cmd = ["dc_shell", "-x", dc_tcl_cmd]
        try:
            run_and_tee(exec_cmd, log_file, cwd=proj_root)
        except subprocess.CalledProcessError:
            print("\nError: Local Design Compiler execution failed.")
            sys.exit(1)
    else:
        remote_bash_cmd = f"source ~/labs/EE5327.cshrc && cd {remote_path} && dc_shell -x {shlex.quote(dc_tcl_cmd)}"
        ssh_cmd = [
            "ssh",
            remote_host,
            f"tcsh -c {shlex.quote(remote_bash_cmd)}"
        ]
        
        try:
            run_and_tee(ssh_cmd, log_file)
        except subprocess.CalledProcessError:
            print("\nError: Remote Design Compiler execution failed.")
            sys.exit(1)

    print(f"\n[3/3] Synthesis complete. Log output saved to {log_file}")


if __name__ == "__main__":
    main()
