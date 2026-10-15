#!/usr/bin/env python3
"""
Pont WebSocket entre la simulation Godot et un orchestrateur externe.

  Godot  --(événements JSON)-->  ce serveur  --(HTTP POST)-->  webhook n8n
  Godot  <--(actions JSON)----   ce serveur  <--(réponse)----  n8n

Utilisation :
    pip install websockets
    python tools/bridge_server.py                      # logique Python locale (exemple ci-dessous)
    N8N_WEBHOOK_URL=http://localhost:5678/webhook/drones python tools/bridge_server.py

Puis dans data/config.json :  "external_bridge": { "enabled": true, "url": "ws://127.0.0.1:8765" }

Le webhook n8n reçoit :
    {"type": "event", "name": "fire_detected", "data": {...}, "world": {...}}
et doit répondre (nœud « Respond to Webhook ») :
    {"actions": [ {"type": "dispatch", "role": "action", "count": 2, "target": "event.position"} ]}
Les actions ont exactement le même format que dans data/rules.json.
"""
import asyncio
import json
import os
import urllib.request

import websockets

HOST = os.environ.get("BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "8765"))
N8N_URL = os.environ.get("N8N_WEBHOOK_URL", "")


def post_to_n8n(payload: dict) -> dict:
    req = urllib.request.Request(
        N8N_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8") or "{}"
    data = json.loads(body)
    if isinstance(data, list):  # n8n renvoie parfois une liste d'items
        data = data[0] if data else {}
    return data if isinstance(data, dict) else {}


def local_policy(msg: dict) -> list:
    """Exemple de logique externe en Python (utilisée si N8N_WEBHOOK_URL n'est pas défini).
    Décochez « Règles locales actives » dans l'éditeur en jeu pour que seule cette logique décide."""
    name, data, world = msg["name"], msg.get("data", {}), msg.get("world", {})
    if name == "simulation_started":
        return [{"type": "patrol", "drone": "surveillance"}]
    if name == "fire_detected":
        n = 3 if data.get("intensity", 0) > 3 or world.get("wind_speed", 0) > 6 else 1
        return [
            {"type": "log", "message": f"[Python] feu détecté, envoi de {n} drone(s)", "level": "rule"},
            {"type": "dispatch", "role": "action", "count": n, "target": "event.position"},
            {"type": "observe", "drone": "event.drone_id", "target": "event.position"},
        ]
    if name == "fire_report" and data.get("intensity", 0) > 20 and world.get("available_action_drones", 0) > 0:
        return [{"type": "dispatch", "role": "action", "count": 1, "target": "event.position"}]
    if name == "tank_empty":
        return [{"type": "refill", "drone": "event.drone_id"}]
    if name in ("refill_done", "drone_ready") and data.get("role") == "action":
        if world.get("fire_active"):
            return [{"type": "fight", "drone": "event.drone_id", "target": "world.fire_position"}]
        return [{"type": "return_base", "drone": "event.drone_id"}]
    if name == "battery_low":
        return [{"type": "return_base", "drone": "event.drone_id"}]
    if name == "fire_extinguished":
        acts = [{"type": "return_base", "drone": "role:action"}]
        if world.get("observing_drones", 0) > 0:
            acts.append({"type": "patrol", "drone": "state:OBSERVE"})
        return acts
    return []


async def handler(ws):
    print("Simulation connectée")
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if msg.get("type") != "event":
                continue
            t = msg.get("world", {}).get("time", 0)
            print(f"[{t:7.1f}s] {msg['name']:<20} {msg.get('data', {})}")
            actions = []
            if N8N_URL:
                try:
                    loop = asyncio.get_running_loop()
                    resp = await loop.run_in_executor(None, post_to_n8n, msg)
                    actions = resp.get("actions", [])
                except Exception as exc:  # noqa: BLE001
                    print("  ! erreur n8n :", exc)
            else:
                actions = local_policy(msg)
            for a in actions:
                print("  ->", a)
                await ws.send(json.dumps({"type": "action", "action": a, "event": msg.get("data", {})}))
    except websockets.ConnectionClosed:
        pass
    print("Simulation déconnectée")


async def main():
    mode = f"n8n ({N8N_URL})" if N8N_URL else "logique Python locale"
    print(f"Pont en écoute sur ws://{HOST}:{PORT} — mode : {mode}")
    async with websockets.serve(handler, HOST, PORT):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
