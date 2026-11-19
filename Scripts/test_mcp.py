#!/usr/bin/env python3
"""Exercise the real stdio MCP executable in an isolated, temporary vault."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid
import zipfile

command = sys.argv[1:] if len(sys.argv) > 1 else [str(Path(".build/Tests/debug/WaveMCP").resolve())]
with tempfile.TemporaryDirectory(prefix="WaveMCPTests-") as directory:
    root = Path(directory)
    note_id = str(uuid.uuid4()).upper()
    ref_id = str(uuid.uuid4()).upper()
    (root / "Notes" / "Recherche").mkdir(parents=True)
    (root / "Notes" / "Recherche" / f"{note_id}.md").write_text(
        "# Une idée\n\nTexte **important** pour l’assistant #projet.\n- [ ] Vérifier MCP\n- [x] Construire\n",
        encoding="utf-8",
    )
    (root / "Notes" / "Recherche" / f"{ref_id}.md").write_text(
        "# Référence\n\nVoir [[Une idée]] pour les détails.\n",
        encoding="utf-8",
    )
    attachments = root / "Attachments" / note_id
    attachments.mkdir(parents=True)
    (attachments / "source.txt").write_text("Une source utile.", encoding="utf-8")
    with zipfile.ZipFile(attachments / "document.docx", "w") as document:
        document.writestr("word/document.xml", '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Une idée dans Word.</w:t></w:r></w:p></w:body></w:document>')
    stream = b"BT /F1 12 Tf 50 700 Td (PDF fixture text) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
               b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, obj in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(pdf)
    pdf.extend(b"xref\n0 6\n0000000000 65535 f \n")
    for offset in offsets:
        pdf.extend(f"{offset:010d} 00000 n \n".encode())
    pdf.extend(f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    (attachments / "document.pdf").write_bytes(pdf)
    env = dict(os.environ, WAVE_VAULT_PATH=directory, WAVE_MCP_WRITE="0")
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    request_id = 0
    def call(method, params=None):
        global request_id
        request_id += 1
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        assert response["id"] == request_id, response
        return response
    def tool(name, arguments):
        return call("tools/call", {"name": name, "arguments": arguments})["result"]

    initialized = call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Wave QA", "version": "1"}})["result"]
    assert initialized["protocolVersion"] == "2025-11-25"
    process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    process.stdin.flush()
    assert call("ping")["result"] == {}
    names = {item["name"] for item in call("tools/list")["result"]["tools"]}
    assert names == {"list_notes", "search_notes", "read_note", "read_attachment", "read_mind_map", "list_tasks", "list_tags", "read_backlinks"}
    assert tool("create_note", {"title": "Interdite"})["isError"]
    assert "Une idée" in tool("list_notes", {"folder": "Recherche"})["content"][0]["text"]
    assert note_id in tool("search_notes", {"query": "IMPORTANT"})["content"][0]["text"]
    assert "# Une idée" in tool("read_note", {"id": note_id})["content"][0]["text"]
    assert "Vérifier MCP" in tool("list_tasks", {"completed": False})["content"][0]["text"]
    assert "#projet" in tool("list_tags", {})["content"][0]["text"]
    assert "Référence" in tool("read_backlinks", {"id": note_id})["content"][0]["text"]
    assert tool("read_attachment", {"note_id": note_id, "filename": "source.txt"})["content"][0]["text"] == "Une source utile."
    assert "Une idée dans Word." in tool("read_attachment", {"note_id": note_id, "filename": "document.docx"})["content"][0]["text"]
    assert "PDF fixture text" in tool("read_attachment", {"note_id": note_id, "filename": "document.pdf"})["content"][0]["text"]
    assert tool("read_attachment", {"note_id": note_id, "filename": "../../secret.txt"})["isError"]
    assert tool("read_note", {"id": "invalid"})["isError"]
    assert tool("unknown_tool", {})["isError"]
    assert "Nœuds" in tool("read_mind_map", {})["content"][0]["text"]
    resources = call("resources/list")["result"]["resources"]
    assert len(resources) == 3
    assert "# Une idée" in call("resources/read", {"uri": f"wave://notes/{note_id}"})["result"]["contents"][0]["text"]
    assert "error" in call("resources/read", {"uri": f"other://notes/{note_id}"})
    assert "error" in call("resources/read", {"uri": f"wave://notes/extra/{note_id}"})
    assert call("not_a_method")["error"]["code"] == -32601
    process.stdin.write("{malformed\n")
    process.stdin.flush()
    assert json.loads(process.stdout.readline())["error"]["code"] == -32700
    process.stdin.write('{"jsonrpc":"2.0","id":1000}\n')
    process.stdin.flush()
    assert json.loads(process.stdout.readline())["error"]["code"] == -32600
    process.stdin.close()
    assert process.wait(timeout=10) == 0

    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=dict(env, WAVE_MCP_WRITE="1"))
    names = {item["name"] for item in call("tools/list")["result"]["tools"]}
    assert {"create_note", "update_note", "list_tasks", "list_tags", "read_backlinks"}.issubset(names)
    assert tool("create_note", {"title": "\n"})["isError"]
    assert tool("create_note", {"title": "Titre\ninjecté"})["isError"]
    assert tool("create_note", {"title": "Titre", "content": 12})["isError"]
    created = tool("create_note", {"title": "Note IA", "content": "Texte initial 🧑🏽‍💻", "folder": "Recherche"})
    assert not created["isError"]
    identity = created["structuredContent"]
    created_id = identity["id"]
    assert identity["revision"].startswith("sha256:")
    assert (root / "Notes" / "Recherche" / f"{created_id}.md").exists()
    read = tool("read_note", {"id": created_id})
    assert read["structuredContent"]["revision"] == identity["revision"]
    assert "Texte initial" in read["content"][0]["text"]
    assert tool("update_note", {"id": created_id, "content": "Sans révision"})["isError"]
    updated = tool("update_note", {"id": created_id, "revision": identity["revision"],
                                   "title": "Note révisée", "content": "Texte corrigé", "folder": "Projet"})
    assert not updated["isError"]
    assert updated["structuredContent"]["revision"] != identity["revision"]
    assert not (root / "Notes" / "Recherche" / f"{created_id}.md").exists()
    moved = root / "Notes" / "Projet" / f"{created_id}.md"
    assert "Texte corrigé" in moved.read_text(encoding="utf-8")
    assert tool("update_note", {"id": created_id, "revision": identity["revision"], "content": "Écrasement"})["isError"]
    assert "Texte corrigé" in moved.read_text(encoding="utf-8")
    latest = tool("read_note", {"id": created_id})["structuredContent"]["revision"]
    moved.write_text("# Changement externe\n\nNouveau texte\n", encoding="utf-8")
    assert tool("update_note", {"id": created_id, "revision": latest, "content": "Écrasement"})["isError"]
    assert "Nouveau texte" in moved.read_text(encoding="utf-8")
    existing_revision = tool("read_note", {"id": note_id})["structuredContent"]["revision"]
    assert not tool("update_note", {"id": note_id, "revision": existing_revision,
                                    "content": "Texte enrichi."})["isError"]
    assert tool("read_attachment", {"note_id": note_id, "filename": "source.txt"})["content"][0]["text"] == "Une source utile."
    process.stdin.close()
    assert process.wait(timeout=10) == 0
    print(f"MCP: {request_id + 2} exchanges passed, including read-only mode, tasks/tags/backlinks, note creation, editing, moves and stale-revision protection.")
