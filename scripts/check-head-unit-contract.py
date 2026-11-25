#!/usr/bin/env python3
"""Read the numbering of a decompiled stock vehicle service and say whether
OpenDash can work with it.

OpenDash talks to the stock service (com.android.hmiserverapp) by number:
a command, an event and a vehicle state are positions in stock lists, and
every Binder call is a transaction code. The app reads those lists from
the service installed on the scooter and works by name, so a list that
grew or was reordered is not a problem in itself. What is a problem: a
name OpenDash uses is gone, or a call it makes has another code.

    apktool d -o /tmp/hhmis HHMIS.apk          # never into this repo
    scripts/check-head-unit-contract.py /tmp/hhmis

    --record contracts/gen<G>-moveos<M>-hhmis-<version>.json
                                               keep what was read as a fixture, for
                                               scooter generation G on MoveOS M
    --emit-kotlin                              rewrite StockFixtures.kt from contracts/
    --emit-kotlin --check                      exit 1 if that file is out of date

Exit 0: OpenDash has every name and call it needs. 1: something it needs is
missing or moved. 2: the inputs could not be read. Nothing is written
unless --record or --emit-kotlin is given, and nothing is run on the scooter.

A fixture is "checked" when OpenDash has been ridden on that exact build:
the flag is set by hand in the JSON, never by this script. On a build that
is not checked the app asks the rider before it sends anything.

Not covered: the parcel layout inside
each call, and what each name means to the scooter.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
KOTLIN = REPO / "android/app/src/main/kotlin/in/abhijithvijayan/opendash/hhmis"
CONTRACTS = REPO / "contracts"
FIXTURES_KT = KOTLIN / "StockFixtures.kt"
DART_COMMANDS = REPO / "lib/providers/vehicle_provider.dart"
SMALI = "com/android/hmiserverapp"
INTERFACES = ("IClientServiceInterface", "IClientServiceInterfaceCallback", "IOTAInterface")

# Our constant -> the stock method it stands for, per interface.
CALLS = {
    "IClientServiceInterface": ("HhmisProxy.kt", {
        "TX_ADD_CALLBACK": "addCallback",
        "TX_REMOVE_CALLBACK": "removeCallback",
        "TX_PASSCODE_ENTERED": "onPasscodeEntered",
        "TX_SYSTEM_BRIGHTNESS": "updateSystemBrightness",
        "TX_SUBSCRIBE_UPDATES": "subscribeToUpdateTrigger",
        "TX_UPDATE_VOLUME": "updateVolume",
        "TX_UPDATE_MOTOR_VOLUME": "updateMotorVolume",
        "TX_UPDATE_CHIME_VOLUME": "updateChimeVolume",
        "TX_VOID_CMD": "onVoidHMICmd",
        "TX_BOOL_CMD": "onBooleanHMICmd",
        "TX_INT_CMD": "onIntegerHMICmd",
        "TX_STRING_CMD": "onStringHMICmd",
    }),
    "IClientServiceInterfaceCallback": ("HhmisCallback.kt", {
        "TX_PASSCODE_VERIFY": "onPassCodeVerify",
        "TX_HARDWARE_INFO": "onUpdateHardwareInfo",
        "TX_WIDGET_INFO": "onWidgetInfo",
        "TX_SCOOTER_UNLOCKED": "onScooterUnlocked",
        "TX_SUN_TIMES": "onSunriseSunsetTimeUpdate",
        "TX_VOLUME_UPDATE": "onVolumeUpdate",
        "TX_MOTOR_VOLUME": "onMotorVolumeUpdate",
        "TX_CHIME_VOLUME": "onPersistedChimeVolumeUpdate",
        "TX_POPUP_COMMAND": "onPopUpCommandReceived",
        "TX_RANGE_BY_MODE": "setRangeKMBasedOnMode",
        "TX_NOTIFICATION_POPUP": "showNotificationPopup",
        "TX_VDP_MISSING": "onVDPCallbackMissing",
        "TX_VOID_UPDATE": "onVoidUpdate",
        "TX_BOOL_UPDATE": "onBooleanUpdate",
        "TX_INT_UPDATE": "onIntegerUpdate",
        "TX_STRING_UPDATE": "onStringUpdate",
        "TX_FLOAT_UPDATE": "onFloatUpdate",
    }),
    "IOTAInterface": ("OtaCallback.kt", {
        "TX_INSTALL_PROGRESS": "installationProgress",
        "TX_FIRST_BOOT": "onFirstTimeBootAfterInstallSuccess",
        "TX_INSTALL_FAILED": "onInstallationFailed",
        "TX_UP_TO_DATE": "onEverythingUptoDate",
        "TX_UPDATE_AVAILABLE": "onUpdateAvailable",
        "TX_DOWNLOAD_DONE": "onDownloadCompleted",
        "TX_DOWNLOAD_STATUS": "onDownloadStatusChanged",
        "TX_RETRY_FAILED": "onDownloadRetryFailed",
    }),
}

# The calls OpenDash must never make: their numbers are checked too, so a
# renumbering cannot move one of them onto a call OpenDash does make.
NEVER = {"download": 8, "install": 9, "triggerReceviedOnHMI": 10}

# The commands OpenDash must never send, and the ones Kotlin sends by itself.
NEVER_SENT = ("BOOL_INSTALL_ERROR_STAT", "VOID_CANCEL_DOWNLOAD", "VOID_CHECK_INSTALL_ERROR_STAT", "VOID_RETRY_DOWNLOAD")
KOTLIN_SENDS = ("BOOL_TOUCH_STATUS", "VOID_CHECK_FOR_UPDATE")

# The vehicle states the app cannot do without (`StockContract.APP_STATES`).
STATES_NEEDED = ("LOCK", "PASSCODE", "PARK", "MOTOR_ON", "REVERSE", "CHARGING")


# A fixture's file says which scooter it came from: the service version
# alone does not, since two generations can run builds of the same MoveOS.
FIXTURE_FILE = re.compile(r"gen(\d+)-moveos(\d+)-hhmis-([\w.\-]+)\.json")


def fixture_label(path):
    """(generation, moveos) from a fixture's file name, or None."""
    m = FIXTURE_FILE.fullmatch(Path(path).name)
    return (int(m.group(1)), int(m.group(2))) if m else None


def find(root, relative):
    for d in sorted(root.glob("smali*")):
        f = d / relative
        if f.is_file():
            return f
    return None


def enum_ordinals(path):
    """name -> ordinal, read from the enum's static constructor."""
    regs, out = {}, {}
    inside = False
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if line.startswith(".method static constructor <clinit>"):
            inside = True
            continue
        if not inside:
            continue
        if line.startswith(".end method"):
            break
        m = re.match(r'const-string(?:/jumbo)? (\w+), "(.*)"$', line)
        if m:
            regs[m.group(1)] = m.group(2)
            continue
        m = re.match(r"const(?:/4|/16|/high16)? (\w+), (-?0x[0-9a-fA-F]+)$", line)
        if m:
            regs[m.group(1)] = int(m.group(2), 16)
            continue
        m = re.match(r"invoke-direct(/range)? \{(.*)\}, L[^;]+;-><init>\(Ljava/lang/String;I", line)
        if m:
            if m.group(1):
                first = re.match(r"(\w)(\d+) \.\. ", m.group(2))
                kind, n = first.group(1), int(first.group(2))
                name_reg, ord_reg = f"{kind}{n + 1}", f"{kind}{n + 2}"
            else:
                parts = [p.strip() for p in m.group(2).split(",")]
                name_reg, ord_reg = parts[1], parts[2]
            name, ordinal = regs.get(name_reg), regs.get(ord_reg)
            if isinstance(name, str) and isinstance(ordinal, int):
                out[name] = ordinal
    return out


def in_order(path):
    ordinals = enum_ordinals(path)
    names = [name for name, _ in sorted(ordinals.items(), key=lambda x: x[1])]
    # A gap would mean an entry was not read: the list is then not the enum.
    return names if sorted(ordinals.values()) == list(range(len(names))) else []


def transactions(path):
    """method -> transaction code, from an AIDL Stub."""
    return {m.group(1): int(m.group(2), 16)
            for m in re.finditer(r"TRANSACTION_(\w+):I = (0x[0-9a-fA-F]+)", path.read_text(errors="replace"))}


def kotlin_consts(path, prefix=""):
    return {m.group(1): int(m.group(2), 0)
            for m in re.finditer(r"const val (" + prefix + r"\w+) = (0x[0-9a-fA-F]+|\d+)\b", path.read_text())}


def commands_needed():
    """Every stock command name the Dart side can send (`HhmisCmd`)."""
    body = DART_COMMANDS.read_text().split("abstract final class HhmisCmd {", 1)[1].split("\n}\n", 1)[0]
    names = set(re.findall(r"'([A-Z][A-Z0-9_]{3,})'", body))
    return sorted((names | set(KOTLIN_SENDS)) - set(NEVER_SENT))


def digest(contract):
    """The same text, line for line, as `StockContract.digest` in Kotlin."""
    lines = [f"{key}:{','.join(contract[key])}" for key in ("commands", "events", "states", "vehicleCommands")]
    lines += [f"{iface}.{method}={code}"
              for iface in sorted(contract["calls"]) for method, code in sorted(contract["calls"][iface].items())]
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def read_contract(root):
    """What a decompile says, or a string saying what could not be read."""
    manifest = root / "AndroidManifest.xml"
    pkg = re.search(r'package="([\w.]+)"', manifest.read_text(errors="replace")) if manifest.is_file() else None
    yml = root / "apktool.yml"
    version = re.search(r"versionName: *['\"]?([\w.\-]+)", yml.read_text()) if yml.is_file() else None
    contract = {"package": pkg.group(1) if pkg else "", "version": version.group(1) if version else "", "calls": {}}
    # The service keeps its vehicle commands in the vehicle interface; the
    # stock dashboard carries a copy among the parcelables.
    for key, places in (
        ("commands", (f"{SMALI}/parcelables/ClientCmd.smali",)),
        ("events", (f"{SMALI}/parcelables/ServerCmd.smali",)),
        ("states", (f"{SMALI}/parcelables/VehicleStates.smali",)),
        ("vehicleCommands", ("com/olaelectric/vehicleinterface/CommandFromVehicle.smali",
                             f"{SMALI}/parcelables/CommandFromVehicle.smali")),
    ):
        f = next((f for f in (find(root, p) for p in places) if f is not None), None)
        if f is None:
            if key in ("commands", "events"):
                return f"cannot find {places[0].rsplit('/', 1)[1]} under {root} (is this an apktool output of HHMIS?)"
            contract[key] = []
            continue
        contract[key] = in_order(f)
        if not contract[key]:
            return f"could not read the entries of {f}"
    for iface in INTERFACES:
        f = find(root, f"{SMALI}/{iface}$Stub.smali")
        if f is None:
            return f"cannot find {iface}$Stub.smali"
        contract["calls"][iface] = transactions(f)
    return contract


def fixtures():
    out = []
    for f in sorted(CONTRACTS.glob("*.json")):
        fixture = json.loads(f.read_text())
        fixture["file"] = f.name
        fixture["digest"] = digest(fixture)
        out.append(fixture)
    return out


def kotlin_list(names, indent="        "):
    lines, line = [], indent
    for name in names:
        piece = f'"{name}", '
        if len(line) + len(piece) > 118:
            lines.append(line.rstrip())
            line = indent
        line += piece
    if line.strip():
        lines.append(line.rstrip())
    return "\n".join(lines)


def emit_kotlin():
    all_fixtures = fixtures()
    # The app's own numbering of vehicle commands: every name any recorded
    # build has, in the order first seen, so a number the Dart side already
    # uses never changes when a newer build is recorded.
    app_commands = []
    for fixture in sorted(all_fixtures, key=lambda f: len(f["vehicleCommands"])):
        app_commands += [n for n in fixture["vehicleCommands"] if n not in app_commands]
    parts = [
        "package `in`.abhijithvijayan.opendash.hhmis",
        "",
        "// Written by scripts/check-head-unit-contract.py --emit-kotlin from contracts/*.json.",
        "// Do not edit: change the JSON and run the script.",
        "",
        "/// The stock builds whose lists have been recorded. A scooter's own",
        "/// service is read first (`StockReader`); these are what its lists are",
        "/// recognised against, and what is used when it cannot be read.",
        "object StockFixtures {",
        "    val APP_VEHICLE_COMMANDS: List<String> = listOf(",
        kotlin_list(app_commands),
        "    )",
        "",
        "    val ALL: List<StockContract> = listOf(",
    ]
    for fixture in all_fixtures:
        parts += [
            f"        // {fixture['scooter']}" + (f" ({fixture['moveosVersion']})" if fixture.get("moveosVersion") else "")
            + f", contracts/{fixture['file']}",
            "        StockContract(",
            f'            name = "{fixture["name"]}",',
            f'            version = "{fixture["version"]}",',
            '            source = "fixture",',
            f'            checked = {"true" if fixture.get("checked") else "false"},',
            f'            fallbackFor = "{fixture.get("fallbackFor", "")}",',
            f'            recordedDigest = "{fixture["digest"]}",',
        ]
        for key in ("commands", "events", "states", "vehicleCommands"):
            parts += [f"            {key} = listOf(", kotlin_list(fixture[key], "                "), "            ),"]
        parts.append("            calls = mapOf(")
        for iface in sorted(fixture["calls"]):
            pairs = ", ".join(f'"{m}" to {c}' for m, c in sorted(fixture["calls"][iface].items(), key=lambda x: x[1]))
            parts.append(f'                "{iface}" to mapOf({pairs}),')
        parts += ["            ),", "        ),"]
    parts += ["    )", "}", ""]
    return "\n".join(parts)


def name_changes(base, theirs):
    """Lines saying how [theirs] differs from [base], both lists of names."""
    at = {name: i for i, name in enumerate(theirs)}
    out = [f"    {name}: {i} -> {at[name]}" for i, name in enumerate(base) if name in at and at[name] != i]
    out += [f"    {name}: {i} -> gone" for i, name in enumerate(base) if name not in at]
    out += [f"    new: {i} {name}" for i, name in enumerate(theirs) if name not in base]
    return out


def main():
    args = sys.argv[1:]
    if "--emit-kotlin" in args:
        text = emit_kotlin()
        if "--check" in args:
            if FIXTURES_KT.is_file() and FIXTURES_KT.read_text() == text:
                return 0
            print(f"{FIXTURES_KT.relative_to(REPO)} is not what contracts/*.json gives: run --emit-kotlin")
            return 1
        FIXTURES_KT.write_text(text)
        print(f"wrote {FIXTURES_KT.relative_to(REPO)}")
        return 0

    record = None
    if "--record" in args:
        at = args.index("--record")
        if at + 1 >= len(args):
            print(__doc__)
            return 2
        record = Path(args[at + 1])
        del args[at:at + 2]
        if fixture_label(record) is None:
            print(f"{record.name}: name the fixture gen<G>-moveos<M>-hhmis-<version>.json, for the scooter it came from")
            return 2
    args = [a for a in args if not a.startswith("--")]
    if len(args) != 1 or not Path(args[0]).is_dir():
        print(__doc__)
        return 2
    root = Path(args[0])
    contract = read_contract(root)
    if isinstance(contract, str):
        print(contract)
        return 2
    problems = []

    copy = contract["package"] != "com.android.hmiserverapp"
    if copy:
        print(f"note: this is {contract['package'] or 'not the service'}, not the service itself. It carries a copy of the\n"
              "      same lists, which the service on that scooter may extend; the app reads the service's own.")
    known = fixtures()
    same = next((f for f in known if f["digest"] == digest(contract) and f["version"] == contract["version"]), None)
    print(f"version: {contract['version'] or 'unknown (no apktool.yml)'}")
    if same:
        print(f"recorded: {same['file']}" + ("  (checked: OpenDash has run on this build)" if same.get("checked") else "  (NOT checked)"))
    else:
        print("recorded: no, these lists are not in contracts/  (NOT checked)")

    base = same or next((f for f in known if f.get("checked")), None)
    for key, label in (("commands", "ClientCmd"), ("events", "ServerCmd"), ("states", "VehicleStates"),
                       ("vehicleCommands", "CommandFromVehicle")):
        changes = [] if base is None or base is same else name_changes(base[key], contract[key])
        print(f"{label}: {len(contract[key])}" + (f", against {base['file']}:" if changes else ""))
        for line in changes[:400]:
            print(line)

    needed = commands_needed()
    missing = [name for name in needed if name not in contract["commands"]]
    print(f"commands OpenDash sends: {len(needed)}, {len(needed) - len(missing)} of them in this build")
    for name in missing:
        problems.append(f"command {name}")
        print(f"  DIFFERENT  {name} is not a command here: the button that sends it would do nothing")
    for name in NEVER_SENT:
        if name not in contract["commands"]:
            print(f"  note: never-sent {name} does not exist here")
    for name in STATES_NEEDED:
        if contract["states"] and name not in contract["states"]:
            problems.append(f"state {name}")
            print(f"  DIFFERENT  vehicle state {name} does not exist here")

    for iface, (kt, names) in CALLS.items():
        theirs = contract["calls"][iface]
        by_code = {c: m for m, c in theirs.items()}
        ours = kotlin_consts(KOTLIN / kt, "TX_")
        print(f"{iface}: {len(ours)} calls used here, {len(theirs)} in the APK")
        for const, method in names.items():
            if const not in ours:
                problems.append(f"{iface} {const}")
                print(f"  DIFFERENT  {const} is no longer in {kt}")
            elif theirs.get(method) != ours[const]:
                problems.append(f"{iface} {const}")
                print(f"  DIFFERENT  {const} = {ours[const]} here, {method} is {theirs.get(method, 'gone')} in the APK")
        for const in sorted(set(ours) - set(names)):
            problems.append(f"{iface} {const}")
            print(f"  NOT PINNED  {const} = {ours[const]} -> {by_code.get(ours[const], 'NOTHING')}: add it to CALLS")
        if iface == "IClientServiceInterface":
            for method, code in NEVER.items():
                if theirs.get(method) != code:
                    problems.append(f"never-sent {method}")
                    print(f"  DIFFERENT  never-sent {method} was {code}, is {theirs.get(method, 'gone')}: "
                          "check HhmisProxy and test/firmware_never_sent_test.dart")
            used = set(ours.values())
            for method, code in NEVER.items():
                if theirs.get(method) in used:
                    problems.append(f"never-sent {method} collides")
                    print(f"  DANGER  {method} now has a number OpenDash sends")

    if record is not None:
        old = json.loads(record.read_text()) if record.is_file() else {}
        generation, moveos = fixture_label(record)
        if record.name != f"gen{generation}-moveos{moveos}-hhmis-{contract['version']}.json":
            print(f"{record.name} does not carry this build's version, {contract['version']}: nothing recorded")
            return 2
        out = {
            "name": f"gen{generation}-moveos{moveos}-{contract['version']}",
            # Which scooter the APK came from, in words. Set by hand.
            "scooter": old.get("scooter", f"Gen {generation} on MoveOS {moveos}"),
            "generation": generation,
            "moveos": moveos,
            # The whole MoveOS build (`versions.txt` of the pull), when known. Set by hand.
            "moveosVersion": old.get("moveosVersion", ""),
            "version": contract["version"],
            "package": contract["package"],
            # Set by hand, once OpenDash has been ridden on this exact build.
            "checked": bool(old.get("checked", False)),
            # A version prefix this fixture stands in for when the service
            # on the scooter cannot be read. Set by hand.
            "fallbackFor": old.get("fallbackFor", ""),
            **{key: contract[key] for key in ("commands", "events", "states", "vehicleCommands")},
            "calls": {iface: dict(sorted(contract["calls"][iface].items(), key=lambda x: x[1])) for iface in INTERFACES},
        }
        record.write_text(json.dumps(out, indent=1) + "\n")
        print(f"recorded as {record}")

    print()
    if problems:
        print(f"{len(problems)} difference(s): OpenDash cannot work fully with this build as it is.")
        return 1
    print("No differences in what OpenDash needs: every command it sends and every call it makes is here.")
    if copy:
        print("This was a copy of the lists. Nothing is marked checked on it: run this on the service's own APK.")
    elif not (same and same.get("checked")):
        print("Not a checked build: the app will ask the rider first. To mark it checked after a ride, record it\n"
              "with --record and set \"checked\": true in the JSON.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
