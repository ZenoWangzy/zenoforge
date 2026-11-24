import base64, json, re
import sys
from email.message import EmailMessage

to_addr, subject, body_path, issue_marker, mailer_id, html_path, images_path, attachment_path = sys.argv[1:9]
def read_text(path):
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()
body, html_body, images_json = read_text(body_path), read_text(html_path), read_text(images_path)
msg = EmailMessage()
msg["To"] = to_addr
msg["Subject"] = subject
msg["X-Zenoforge-Agent-Mailer"] = "zf-pipeline-v1"
msg["X-Zenoforge-Agent-Mailer-ID"] = mailer_id
if issue_marker:
    msg["X-Zenoforge-Agent-Issue"] = issue_marker
msg.set_content(body)
if html_body:
    msg.add_alternative(html_body, subtype="html")
    html_part = msg.get_payload()[-1]
    images = json.loads(images_json)
    if not isinstance(images, list) or len(images) > 8: raise ValueError("invalid inline images")
    seen = set()
    for image in images:
        cid = image.get("cid", "")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", cid) or cid in seen or "cid:"+cid not in html_body: raise ValueError("invalid image CID")
        seen.add(cid)
        data = base64.b64decode(image.get("data", ""), validate=True)
        if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) > 2_000_000: raise ValueError("invalid PNG")
        html_part.add_related(data, maintype="image", subtype="png", cid="<"+cid+">", filename=image.get("filename", cid+".png"), disposition="inline")
if attachment_path:
    with open(attachment_path, encoding="utf-8") as handle:
        msg.add_attachment(handle.read(), subtype="plain", filename="decision-log-review.txt")
sys.stdout.write(base64.urlsafe_b64encode(msg.as_bytes()).decode("ascii"))
