import os
import sys
import subprocess
import argparse

def main():
    parser = argparse.ArgumentParser(description="Remote FPGA Build Utility")
    parser.add_argument("remote", help="Remote SSH host (e.g., desktop or user@host)")
    parser.add_argument(
        "--flash", 
        choices=['fpga', 'spi', 'none'], 
        default='none', 
        help="Flash target"
    )
    args = parser.parse_args()

    proj_root = os.path.dirname(os.path.abspath(__file__))
    remote_path = "~/projects/srfft"
    
    FIND_VIVADO_CMD = (
        'if which vivado >/dev/null 2>&1; then '
            'echo "Vivado already in PATH"; '
        'elif module avail 2>&1 | grep -i xilinx >/dev/null 2>&1; then '
            'module load xilinx >/dev/null 2>&1 || module load xilinx/vivado >/dev/null 2>&1; '
        'elif [ -f "/tools/Xilinx/2025.2/Vivado/settings64.sh" ]; then '
            'source "/tools/Xilinx/2025.2/Vivado/settings64.sh"; '
        'else '
            'V_SET=$(find /tools /soft /opt /usr/local -name settings64.sh 2>/dev/null | grep -i vivado | sort -r | head -n 1); '
            'if [ -n "$V_SET" ]; then '
                'source "$V_SET"; '
            'elif [ -n "$XILINX_VIVADO" ] && [ -f "$XILINX_VIVADO/settings64.sh" ]; then '
                'source "$XILINX_VIVADO/settings64.sh"; '
            'else '
                'echo "ERROR: Could not locate Vivado settings64.sh on remote system."; exit 1; '
            'fi; '
        'fi'
    )

    print(f"\n[1/3] Syncing source to {args.remote}...")
    rsync_cmd = [
        "rsync", "-avz", "--delete",
        "--exclude", ".git/", "--exclude", "sim/gen/", "--exclude", "syn/gen/",
        f"{proj_root}/", f"{args.remote}:{remote_path}/"
    ]
    
    try:
        subprocess.check_call(rsync_cmd)
    except subprocess.CalledProcessError:
        print("Error: Rsync failed.")
        sys.exit(1)

    print(f"\n[2/3] Starting remote build on {args.remote}...")
    # Ensures syn/logs directory exists before launching Vivado
    remote_build_cmd = (
        f"{FIND_VIVADO_CMD} && "
        f"mkdir -p {remote_path}/syn/logs && "
        f"cd {remote_path} && "
        "vivado -mode batch -source scripts/build_bitstream.tcl "
        "-log syn/logs/build.log -journal syn/logs/build.jou"
    )
    
    ssh_build_cmd = ["ssh", args.remote, f"bash -l -c '{remote_build_cmd}'"]
    
    try:
        subprocess.check_call(ssh_build_cmd)
    except subprocess.CalledProcessError:
        print("\nError: Remote build failed. Check syn/logs/build.log on remote.")
        sys.exit(1)

if __name__ == "__main__":
    main()
