"""Run the maintained xsim regression with frozen sources and explicit results."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
TESTS = {
    "tb_fifo_sync": "Bsp/Fifo/tb_fifo_sync.sv",
    "tb_axis_buffers": "Bsp/tb_axis_buffers.sv",
    "tb_value_rr_arbiter": "Algorithm/tb_value_rr_arbiter.sv",
    "tb_axis_value_rr_arbiter": "Bsp/Axis/tb_axis_value_rr_arbiter.sv",
    "tb_cfg_port_top": "Config/tb_cfg_port_top.sv",
    "tb_arp_engine_top": "Network/Arp/tb_arp_engine_top.sv",
    "tb_icmpv4_top": "Network/Icmp/tb_icmpv4_top.sv",
    "tb_udp_ipv4_top": "Transport/Udp/Ipv4/tb_udp_ipv4_top.sv",
    "tb_udp_ipv6_top": "Transport/Udp/Ipv6/tb_udp_ipv6_top.sv",
    "tb_arp_announce_integration": "Top/tb_arp_announce_integration.sv",
    "tb_udp_ipv6_integration": "Top/tb_udp_ipv6_integration.sv",
}
MUTATIONS = {
    "skid_keep": ("tb_axis_buffers", "RTL/Bsp/Skid/axis_skid_buffer.v",
                  "assign axis_mkeep  = p1_axis_mkeep;", "assign axis_mkeep  = ~p1_axis_mkeep;",
                  "AXIS data/keep/usr/last mismatch"),
    "config_response": ("tb_cfg_port_top", "RTL/Config/cfg_cmd.v",
                        "assign axis_mdata  = axis_mdata_reg;", "assign axis_mdata  = axis_mdata_reg ^ 1'b1;",
                        "configuration response mismatch"),
    "udp4_checksum": ("tb_udp_ipv4_top", "RTL/Transport/Udp/Ipv4/udp_ipv4_tx.v",
                      ".pkt_head_checksum(pkt_udp_checksum)", ".pkt_head_checksum(pkt_udp_checksum ^ 16'h0001)",
                      "TX data mismatch"),
}
FAILURE = re.compile(r"\b(?:FAIL(?:ED|URE)?|FATAL|ERROR|TIMEOUT)\b|错误", re.IGNORECASE)


def executable(name, directory):
    suffix = ".bat" if os.name == "nt" else ""
    candidate = Path(directory) / (name + suffix) if directory else None
    found = str(candidate.resolve()) if candidate and candidate.is_file() else None
    if directory and not found:
        raise ValueError(f"Tool not found: {candidate}")
    found = found or shutil.which(name + suffix) or shutil.which(name)
    if not found:
        raise ValueError(f"Tool not found: {name}; set --vivado-bin or PATH")
    return found


def stop_process(process):
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    else:
        os.killpg(process.pid, signal.SIGKILL)
    process.wait()


def command(arguments, directory, timeout, log):
    with log.open("w", encoding="utf-8") as output:
        output.write(json.dumps(arguments) + "\n")
        output.flush()
        process = subprocess.Popen(arguments, cwd=directory, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=os.name != "nt")
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_process(process)
            output.write("\nFAIL: wall-clock timeout\n")
            return -1
        except KeyboardInterrupt:
            stop_process(process)
            raise


def run_test(name, snapshot, output, binaries, timeout, report=True):
    directory = output / name
    directory.mkdir()
    sources = sorted((snapshot / "RTL").rglob("*.v"))
    sources += sorted((snapshot / "TB/Top/ip_sim").glob("*.v"))
    sources.append(snapshot / "TB" / TESTS[name])
    source_list = directory / "sources.f"
    source_list.write_text("\n".join('"' + path.as_posix() + '"' for path in sources) + "\n",
                           encoding="utf-8")
    script = directory / "run.tcl"
    script.write_text("run all\nquit\n", encoding="utf-8")
    commands = [
        [binaries["xvlog"], "--sv", "-i", (snapshot / "RTL/Config").as_posix(), "-f", source_list.as_posix()],
        [binaries["xelab"], "-mt", "2", "-s", "test_snapshot", "work." + name],
        [binaries["xsim"], "test_snapshot", "-tclbatch", script.as_posix()],
    ]
    started = time.monotonic()
    result = {"test": name, "status": "FAIL", "commands": commands}
    try:
        for stage, arguments in zip(("compile", "elaborate", "simulate"), commands):
            log = directory / (stage + ".log")
            returncode = command(arguments, directory, timeout, log)
            text = log.read_text(encoding="utf-8", errors="replace")
            if returncode != 0 or FAILURE.search(text):
                result.update(stage=stage, returncode=returncode, log=str(log))
                result["diagnostics"] = [line for line in text.splitlines() if FAILURE.search(line)][:8]
                break
        else:
            if re.search(r"(?m)^PASS: " + re.escape(name) + r"\s*$", text):
                result["status"] = "PASS"
            else:
                result.update(stage="simulate", log=str(log), reason="Missing final PASS marker")
    except (OSError, ValueError) as error:
        result["reason"] = str(error)
    result["seconds"] = round(time.monotonic() - started, 2)
    if report:
        print(f"{result['status']}: {name}", flush=True)
    return result


def run_mutation(name, snapshot, output, binaries, timeout):
    test, path, before, after, expected = MUTATIONS[name]
    directory = output / "mutations" / name
    mutated = directory / "src"
    shutil.copytree(snapshot, mutated)
    target = mutated / path
    source = target.read_text(encoding="utf-8")
    if source.count(before) != 1:
        result = {"mutation": name, "status": "FAIL", "reason": "Mutation target is not unique"}
    else:
        target.write_text(source.replace(before, after), encoding="utf-8")
        result = run_test(test, mutated, directory, binaries, timeout, report=False)
        log = Path(result["log"]).read_text(encoding="utf-8", errors="replace") if "log" in result else ""
        detected = (result["status"] == "FAIL" and result.get("stage") == "simulate"
                    and re.search(r"(?im)^Fatal:.*" + re.escape(expected), log) is not None)
        result.update(mutation=name, status="DETECTED" if detected else "FAIL",
                      patch={"path": path, "before": before, "after": after,
                             "sha256": hashlib.sha256(target.read_bytes()).hexdigest()},
                      expected_diagnostic=expected)
    print(f"{result['status']}: mutation {name}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--test", nargs="+", choices=TESTS)
    parser.add_argument("--vivado-bin", default=os.environ.get("VIVADO_BIN"))
    parser.add_argument("--jobs", type=int, choices=(1, 2), default=1)
    parser.add_argument("--timeout", type=int, default=600, help="Seconds per tool stage")
    parser.add_argument("--mutation-check", action="store_true", help="Also check three deliberate errors in frozen RTL copies")
    args = parser.parse_args()
    if args.list:
        print("\n".join(TESTS))
        return 0
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        binaries = {name: executable(name, args.vivado_bin) for name in ("xvlog", "xelab", "xsim")}
    except ValueError as error:
        parser.error(str(error))
    output = ROOT / "build/tb" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    snapshot = output / "src"
    snapshot.mkdir(parents=True)
    paths = sorted((ROOT / "RTL").rglob("*.v")) + sorted((ROOT / "RTL").rglob("*.vh"))
    paths = [path for path in paths if "Backup" not in path.relative_to(ROOT).parts]
    paths += sorted((ROOT / "TB").rglob("*.sv")) + sorted((ROOT / "TB/Top/ip_sim").glob("*.v"))
    paths.append(Path(__file__).resolve())
    manifest = {}
    for path in paths:
        relative = path.relative_to(ROOT)
        data = path.read_bytes()
        target = snapshot / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        manifest[relative.as_posix()] = hashlib.sha256(data).hexdigest()
    manifest_text = json.dumps(manifest, indent=2) + "\n"
    (output / "sources.sha256.json").write_bytes(manifest_text.encode("utf-8"))
    print(f"Results: {output}", flush=True)
    names = list(dict.fromkeys(args.test or TESTS))
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        results = list(executor.map(lambda name: run_test(name, snapshot, output, binaries, args.timeout), names))
    mutations = []
    if args.mutation_check:
        with ThreadPoolExecutor(max_workers=args.jobs) as executor:
            mutations = list(executor.map(lambda name: run_mutation(name, snapshot, output, binaries, args.timeout), MUTATIONS))
    versions = sorted(set(match.group(0) for name in names for match in re.finditer(
        r"Vivado Simulator v[^\r\n]+", (output / name / "elaborate.log").read_text(
            encoding="utf-8", errors="replace") if (output / name / "elaborate.log").is_file() else "")))
    summary = {"utc": datetime.now(timezone.utc).isoformat(), "tools": binaries,
               "versions": versions, "python": sys.version.split()[0],
               "sources_sha256": hashlib.sha256(manifest_text.encode("utf-8")).hexdigest(),
               "results": results, "mutations": mutations}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    failed = sum(result["status"] != "PASS" for result in results)
    print(f"{len(results) - failed}/{len(results)} passed; summary: {output / 'summary.json'}")
    return 1 if failed or any(result["status"] != "DETECTED" for result in mutations) else 0


if __name__ == "__main__":
    sys.exit(main())
