#!/usr/bin/env python3
import argparse
import copy
import json
import os
import re
import socket
import sys
import tempfile
from pathlib import Path

import yaml

STATIC_PROVIDER_ENV_KEYS = {
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "OPENROUTER_API_KEY",
    "TOGETHER_API_KEY",
    "GROQ_API_KEY",
    "DEEPSEEK_API_KEY",
    "MISTRAL_API_KEY",
    "XAI_API_KEY",
    "COHERE_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "AZURE_OPENAI_ENDPOINT",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_REGION",
    "AWS_DEFAULT_REGION",
}


def load_yaml(path: Path):
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return data or {}


def atomic_write_yaml(path: Path, data, mode: int = 0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            yaml.safe_dump(data, f, sort_keys=False, allow_unicode=True)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def parse_env(path: Path):
    result = {}
    if not path.exists():
        return result
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key:
            result[key] = value
    return result


def write_env(path: Path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{k}={v}" for k, v in values.items()]
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            if lines:
                f.write("\n".join(lines) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def collect_key_envs(obj, out):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == "key_env" and isinstance(value, str) and value:
                out.add(value)
            else:
                collect_key_envs(value, out)
    elif isinstance(obj, list):
        for value in obj:
            collect_key_envs(value, out)



def collect_env_refs(obj, out):
    if isinstance(obj, dict):
        for value in obj.values():
            collect_env_refs(value, out)
    elif isinstance(obj, list):
        for value in obj:
            collect_env_refs(value, out)
    elif isinstance(obj, str):
        for match in re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", obj):
            out.add(match)


def provider_env_keys(hermes_install_dir: Path, default_config):
    keys = set(STATIC_PROVIDER_ENV_KEYS)
    collect_key_envs(default_config.get("model", {}), keys)
    collect_key_envs(default_config.get("custom_providers", {}), keys)
    collect_key_envs(default_config.get("providers", {}), keys)
    collect_key_envs(default_config.get("model_aliases", {}), keys)
    for section in ("model", "providers", "custom_providers", "model_aliases", "provider_routing", "openrouter", "auxiliary"):
        collect_env_refs(default_config.get(section, {}), keys)

    sys.path.insert(0, str(hermes_install_dir))
    try:
        from providers import list_providers  # type: ignore

        for provider in list_providers():
            env_vars = getattr(provider, "env_vars", None) or []
            for key in env_vars:
                if isinstance(key, str) and key:
                    keys.add(key)

        # Hermes 0.21.x also keeps provider metadata such as base-URL env vars
        # in hermes_cli.providers overlays. Carry those values when present so
        # the inherited provider behaves exactly like the working default.
        try:
            from hermes_cli.providers import HERMES_OVERLAYS  # type: ignore

            for overlay in HERMES_OVERLAYS.values():
                base_key = getattr(overlay, "base_url_env_var", "") or ""
                if base_key:
                    keys.add(base_key)
                for key in getattr(overlay, "extra_env_vars", ()) or ():
                    if isinstance(key, str) and key:
                        keys.add(key)
        except Exception:
            pass
    except Exception:
        # Static keys + model key_env remain the safe fallback.
        pass
    finally:
        try:
            sys.path.remove(str(hermes_install_dir))
        except ValueError:
            pass
    return keys


def command_inherit_llm(args):
    hermes_root = Path(args.hermes_root).expanduser().resolve()
    target = Path(args.target_profile).expanduser().resolve()
    install_dir = Path(args.hermes_install_dir).expanduser().resolve()

    default_config_path = hermes_root / "config.yaml"
    target_config_path = target / "config.yaml"
    default_env_path = hermes_root / ".env"
    target_env_path = target / ".env"

    default_config = load_yaml(default_config_path)
    model = default_config.get("model")
    if not model:
        raise SystemExit("Default Hermes profile has no model configuration in config.yaml")

    target_config = load_yaml(target_config_path)
    llm_sections = (
        "model",
        "providers",
        "custom_providers",
        "model_aliases",
        "provider_routing",
        "openrouter",
        "auxiliary",
        "prompt_caching",
    )
    for section in llm_sections:
        if section in default_config:
            target_config[section] = copy.deepcopy(default_config[section])
    atomic_write_yaml(target_config_path, target_config)

    default_env = parse_env(default_env_path)
    target_env = parse_env(target_env_path)
    allowed_keys = provider_env_keys(install_dir, default_config)
    copied = []
    for key in sorted(allowed_keys):
        source_value = default_env.get(key, os.environ.get(key))
        if source_value is not None:
            target_env[key] = source_value
            copied.append(key)
        index = 2
        while True:
            sibling = f"{key}_{index}"
            sibling_value = default_env.get(sibling, os.environ.get(sibling))
            if sibling_value is None:
                break
            target_env[sibling] = sibling_value
            copied.append(sibling)
            index += 1
    write_env(target_env_path, target_env)

    provider = None
    model_name = None
    if isinstance(model, dict):
        provider = model.get("provider")
        model_name = model.get("name") or model.get("model")
    elif isinstance(model, str):
        model_name = model

    summary = []
    if provider:
        summary.append(f"provider={provider}")
    if model_name:
        summary.append(f"model={model_name}")
    summary.append(f"credential_keys_copied={len(copied)}")
    print(" ".join(summary))


def port_is_free(port: int):
    sockets = []
    try:
        s4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s4.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s4.bind(("0.0.0.0", port))
        sockets.append(s4)

        if socket.has_ipv6:
            try:
                s6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
                s6.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    s6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                except OSError:
                    pass
                s6.bind(("::", port))
                sockets.append(s6)
            except OSError:
                return False
        return True
    except OSError:
        return False
    finally:
        for sock in sockets:
            sock.close()


def command_find_free_port(args):
    for port in range(args.start, args.end + 1):
        if port_is_free(port):
            print(port)
            return
    raise SystemExit(f"No free TCP port found in range {args.start}-{args.end}")



def _truthy(value):
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def _platform_config(config, name):
    for root in (config.get("platforms"), (config.get("gateway") or {}).get("platforms")):
        if isinstance(root, dict) and isinstance(root.get(name), dict):
            return root[name]
    return {}



def command_multiplex_active(args):
    hermes_root = Path(args.hermes_root).expanduser().resolve()
    config = load_yaml(hermes_root / "config.yaml")
    env = parse_env(hermes_root / ".env")

    gateway = config.get("gateway") if isinstance(config.get("gateway"), dict) else {}
    configured = (
        _truthy(env.get("GATEWAY_MULTIPLEX_PROFILES"))
        or _truthy(gateway.get("multiplex_profiles"))
        or _truthy(config.get("multiplex_profiles"))
    )
    if configured:
        print("configured")
        return

    state_path = hermes_root / "gateway_state.json"
    if state_path.exists():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            state = {}
        served = state.get("served_profiles") if isinstance(state, dict) else None
        if isinstance(served, list) and any(
            isinstance(name, str) and name and name != "default" for name in served
        ):
            print("running")
            return

    raise SystemExit("Default Hermes gateway is not explicitly or observably multiplexing")

def command_shared_listener_port(args):
    hermes_root = Path(args.hermes_root).expanduser().resolve()
    config = load_yaml(hermes_root / "config.yaml")
    env = parse_env(hermes_root / ".env")

    api_cfg = _platform_config(config, "api_server")
    api_enabled = _truthy(env.get("API_SERVER_ENABLED")) or _truthy(api_cfg.get("enabled"))
    if api_enabled:
        extra = api_cfg.get("extra") if isinstance(api_cfg.get("extra"), dict) else {}
        port = env.get("API_SERVER_PORT") or extra.get("port") or api_cfg.get("port") or 8642
        print(int(port))
        return

    webhook_cfg = _platform_config(config, "webhook")
    webhook_enabled = _truthy(env.get("WEBHOOK_ENABLED")) or _truthy(webhook_cfg.get("enabled"))
    if webhook_enabled:
        extra = webhook_cfg.get("extra") if isinstance(webhook_cfg.get("extra"), dict) else {}
        port = env.get("WEBHOOK_PORT") or extra.get("port") or webhook_cfg.get("port") or 8644
        print(int(port))
        return

    raise SystemExit("No default-profile shared HTTP listener is configured")


def command_write_manifest(args):
    data = {
        "source": "cerjary/hermes-first-agent",
        "version": args.version,
        "agent_id": args.agent_id,
        "display_name": args.display_name,
        "tenant_code": args.tenant_code,
        "business_code": args.business_code or "none",
        "installed_at": args.installed_at,
        "gateway_topology": args.topology,
        "gateways": args.platform,
    }
    if args.line_port:
        data["line_port"] = int(args.line_port)
    atomic_write_yaml(Path(args.path).expanduser().resolve(), data)


def command_set_manifest_version(args):
    path = Path(args.path).expanduser().resolve()
    data = load_yaml(path)
    if not isinstance(data, dict):
        raise SystemExit("Manifest is not a YAML mapping")
    data["version"] = args.version
    atomic_write_yaml(path, data)



def command_verify_manifest(args):
    path = Path(args.path).expanduser().resolve()
    data = load_yaml(path)
    if not isinstance(data, dict):
        raise SystemExit("Manifest is not a YAML mapping")
    if data.get("source") != "cerjary/hermes-first-agent":
        raise SystemExit("Profile source does not match hermes-first-agent")
    if data.get("agent_id") != args.agent_id:
        raise SystemExit("Manifest agent_id does not match the requested Agent ID")
    print(data.get("version", "unknown"))


def build_parser():
    parser = argparse.ArgumentParser(description="Hermes First Agent installer helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("inherit-llm")
    p.add_argument("--hermes-root", required=True)
    p.add_argument("--hermes-install-dir", required=True)
    p.add_argument("--target-profile", required=True)
    p.set_defaults(func=command_inherit_llm)

    p = sub.add_parser("find-free-port")
    p.add_argument("--start", type=int, default=8646)
    p.add_argument("--end", type=int, default=8999)
    p.set_defaults(func=command_find_free_port)


    p = sub.add_parser("multiplex-active")
    p.add_argument("--hermes-root", required=True)
    p.set_defaults(func=command_multiplex_active)

    p = sub.add_parser("shared-listener-port")
    p.add_argument("--hermes-root", required=True)
    p.set_defaults(func=command_shared_listener_port)

    p = sub.add_parser("write-manifest")
    p.add_argument("--path", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--agent-id", required=True)
    p.add_argument("--display-name", required=True)
    p.add_argument("--tenant-code", required=True)
    p.add_argument("--business-code", default="")
    p.add_argument("--installed-at", required=True)
    p.add_argument("--topology", required=True)
    p.add_argument("--platform", action="append", default=[])
    p.add_argument("--line-port", default="")
    p.set_defaults(func=command_write_manifest)

    p = sub.add_parser("set-manifest-version")
    p.add_argument("--path", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(func=command_set_manifest_version)

    p = sub.add_parser("verify-manifest")
    p.add_argument("--path", required=True)
    p.add_argument("--agent-id", required=True)
    p.set_defaults(func=command_verify_manifest)
    return parser


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
