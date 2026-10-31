"""Callbacks de monitoramento (falha, retry e sucesso).

Por padrão registram um log estruturado (visível na UI e no `kubectl logs`).
Se a variável de ambiente BANVIC_ALERT_WEBHOOK_URL estiver definida
(ex.: webhook do Slack/Teams guardado em um Secret), também enviam um alerta.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request
from typing import Any

from airflow.sdk.log import mask_secret

log = logging.getLogger("banvic.alerts")


def _webhook_url() -> str | None:
    """URL do webhook (é uma credencial: quem tem a URL posta no canal). Sempre mascarada."""
    url = os.getenv("BANVIC_ALERT_WEBHOOK_URL")
    if url:
        mask_secret(url, name="BANVIC_ALERT_WEBHOOK_URL")
    return url


_webhook_url()


def _payload(context: dict[str, Any], event: str) -> dict[str, Any]:
    ti = context.get("task_instance") or context.get("ti")
    dag_run = context.get("dag_run")
    return {
        "event": event,
        "dag_id": getattr(ti, "dag_id", None) or getattr(dag_run, "dag_id", None),
        "task_id": getattr(ti, "task_id", None),
        "map_index": getattr(ti, "map_index", None),
        "run_id": getattr(dag_run, "run_id", None),
        "try_number": getattr(ti, "try_number", None),
        "exception": str(context.get("exception") or context.get("reason") or ""),
    }


def _send(payload: dict[str, Any]) -> None:
    url = _webhook_url()
    if not url:
        return
    body = json.dumps({"text": f"[BanVic] {payload['event']}: {json.dumps(payload, default=str)}"})
    request = urllib.request.Request(  # noqa: S310 - URL controlada via Secret
        url, data=body.encode(), headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        urllib.request.urlopen(request, timeout=5)  # noqa: S310
    except Exception as exc:  # noqa: BLE001 - alerta nunca pode derrubar a task
        log.warning("Falha ao enviar alerta: %s", exc)


def notify_task_failure(context: dict[str, Any]) -> None:
    payload = _payload(context, "TASK_FAILED")
    log.error("ALERTA %s", json.dumps(payload, default=str))
    _send(payload)


def notify_task_retry(context: dict[str, Any]) -> None:
    log.warning("RETRY %s", json.dumps(_payload(context, "TASK_RETRY"), default=str))


def notify_dag_failure(context: dict[str, Any]) -> None:
    payload = _payload(context, "DAG_RUN_FAILED")
    log.error("ALERTA %s", json.dumps(payload, default=str))
    _send(payload)


def notify_dag_success(context: dict[str, Any]) -> None:
    log.info("SUCESSO %s", json.dumps(_payload(context, "DAG_RUN_SUCCESS"), default=str))
