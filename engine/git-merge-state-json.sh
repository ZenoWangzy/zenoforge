#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo "usage: $0 BASE OURS THEIRS" >&2; exit 2; }
exec python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import stat
import sys
import tempfile


class MergeConflict(Exception):
    pass


class Document:
    def __init__(self, path):
        self.path = path
        with open(path, encoding="utf-8", newline="") as stream:
            self.text = stream.read()
        self.value = json.loads(self.text)
        self.decoder = json.JSONDecoder()
        if not isinstance(self.value, dict):
            raise ValueError(f"{path}: expected top-level object")
        self.members, self.open_end, self.close_start = self.object_members(0)

    def skip_ws(self, pos):
        while pos < len(self.text) and self.text[pos] in " \t\r\n":
            pos += 1
        return pos

    def decode(self, pos):
        pos = self.skip_ws(pos)
        value, end = self.decoder.raw_decode(self.text, pos)
        return value, pos, end

    def object_members(self, pos):
        text = self.text
        start = self.skip_ws(pos)
        if start >= len(text) or text[start] != "{":
            raise ValueError(f"{self.path}: expected object")
        members = []
        current = self.skip_ws(start + 1)
        while current < len(text) and text[current] != "}":
            key, key_start, key_end = self.decode(current)
            if not isinstance(key, str) or any(member["key"] == key for member in members):
                raise ValueError(f"{self.path}: duplicate or non-string object key")
            colon = self.skip_ws(key_end)
            if colon >= len(text) or text[colon] != ":":
                raise ValueError(f"{self.path}: missing object colon")
            value, value_start, value_end = self.decode(colon + 1)
            members.append({
                "key": key,
                "key_start": key_start,
                "value_start": value_start,
                "value_end": value_end,
                "value": value,
            })
            current = self.skip_ws(value_end)
            if text[current] == ",":
                current = self.skip_ws(current + 1)
            elif text[current] != "}":
                raise ValueError(f"{self.path}: expected comma or object end")
        if current >= len(text):
            raise ValueError(f"{self.path}: unterminated object")
        return members, start + 1, current

    def array_items(self, start, end):
        text = self.text
        if text[start] != "[" or text[end - 1] != "]":
            raise ValueError(f"{self.path}: expected array")
        items = []
        current = self.skip_ws(start + 1)
        while current < end - 1:
            value, item_start, item_end = self.decode(current)
            items.append({"value": value, "start": item_start, "end": item_end})
            current = self.skip_ws(item_end)
            if current < end - 1 and text[current] == ",":
                current = self.skip_ws(current + 1)
            elif current != end - 1:
                raise ValueError(f"{self.path}: expected comma or array end")
        return items

    def raw_value(self, member):
        return self.text[member["value_start"]:member["value_end"]]

    def raw_member(self, member, value_raw=None):
        if value_raw is None:
            return self.text[member["key_start"]:member["value_end"]]
        return self.text[member["key_start"]:member["value_start"]] + value_raw


MISSING = object()


def keyed_items(value, label):
    if value is MISSING or value is None:
        return []
    if not isinstance(value, list) or any(
        not isinstance(item, dict) or not isinstance(item.get("id"), str)
        for item in value
    ):
        raise MergeConflict(f"{label}: array is not keyed by string id")
    result = {}
    for item in value:
        item_id = item["id"]
        if item_id in result:
            raise MergeConflict(f"{label}: duplicate id {item_id}")
        result[item_id] = item
    return result


def merge_array(base_doc, ours_doc, theirs_doc, key, base_member, ours_member, theirs_member):
    base_value = base_member["value"] if base_member else MISSING
    ours_value = ours_member["value"] if ours_member else MISSING
    theirs_value = theirs_member["value"] if theirs_member else MISSING
    base_items = keyed_items(base_value, key)
    ours_items = keyed_items(ours_value, key)
    theirs_items = keyed_items(theirs_value, key)
    ours_order = [item["id"] for item in (ours_value if isinstance(ours_value, list) else [])]
    theirs_order = [item["id"] for item in (theirs_value if isinstance(theirs_value, list) else [])]
    ids = ours_order + [item_id for item_id in theirs_order if item_id not in ours_items]
    selected = {}
    for item_id in ids:
        old = base_items.get(item_id, MISSING)
        left = ours_items.get(item_id, MISSING)
        right = theirs_items.get(item_id, MISSING)
        if old is MISSING:
            if left is not MISSING and right is not MISSING and left != right:
                raise MergeConflict(f"{key}: conflicting addition {item_id}")
            selected[item_id] = ("ours" if left is not MISSING else "theirs")
        elif left is MISSING or right is MISSING:
            if left is MISSING and right is MISSING:
                continue
            survivor = right if left is MISSING else left
            if survivor == old:
                continue
            raise MergeConflict(f"{key}: removal conflicts with edit {item_id}")
        elif left == right or left == old:
            selected[item_id] = "ours" if left == right else "theirs"
        elif right == old:
            selected[item_id] = "ours"
        else:
            raise MergeConflict(f"{key}: conflicting edits to {item_id}")

    raw_by_side = {}
    for side, source_doc, source_member in (
        ("ours", ours_doc, ours_member),
        ("theirs", theirs_doc, theirs_member),
    ):
        entries = source_doc.array_items(source_member["value_start"], source_member["value_end"])
        raw_by_side[side] = {
            item["value"]["id"]: source_doc.text[item["start"]:item["end"]]
            for item in entries
        }
    raw_values = {}
    output_ids = []
    for item_id in ids:
        side = selected.get(item_id)
        if side is None:
            continue
        raw_values[item_id] = raw_by_side[side][item_id]
        output_ids.append(item_id)
    chosen_doc = ours_doc if ours_member is not None else theirs_doc
    chosen_member = ours_member if ours_member is not None else theirs_member
    # Rebuild from selected source entries using the chosen array's whitespace.
    source_items = chosen_doc.array_items(chosen_member["value_start"], chosen_member["value_end"])
    prefix = chosen_doc.text[chosen_member["value_start"] + 1:
                             (source_items[0]["start"] if source_items else chosen_member["value_end"] - 1)]
    suffix_start = source_items[-1]["end"] if source_items else chosen_member["value_start"] + 1
    suffix = chosen_doc.text[suffix_start:chosen_member["value_end"] - 1]
    separator = ""
    for candidate_doc, candidate_member in ((ours_doc, ours_member), (theirs_doc, theirs_member)):
        if candidate_doc is None or candidate_member is None:
            continue
        entries = candidate_doc.array_items(candidate_member["value_start"], candidate_member["value_end"])
        if len(entries) > 1:
            separator = candidate_doc.text[entries[0]["end"]:entries[1]["start"]]
            break
    if not separator:
        separator = ","
    return "[" + prefix + separator.join(raw_values[item_id] for item_id in output_ids) + suffix + "]"


def merge_object_map(base_doc, ours_doc, theirs_doc, key, base_member, ours_member, theirs_member):
    def entries(doc, member):
        if member is None:
            return []
        return doc.object_members(member["value_start"])[0]

    base_entries = {entry["key"]: entry for entry in entries(base_doc, base_member)}
    ours_entries = {entry["key"]: entry for entry in entries(ours_doc, ours_member)}
    theirs_entries = {entry["key"]: entry for entry in entries(theirs_doc, theirs_member)}
    order = list(ours_entries) + [entry_key for entry_key in theirs_entries if entry_key not in ours_entries]
    selected = {}
    for entry_key in order:
        old = base_entries.get(entry_key, MISSING)
        left = ours_entries.get(entry_key, MISSING)
        right = theirs_entries.get(entry_key, MISSING)
        old_value = old["value"] if old is not MISSING else MISSING
        left_value = left["value"] if left is not MISSING else MISSING
        right_value = right["value"] if right is not MISSING else MISSING
        if old is MISSING:
            if left is not MISSING and right is not MISSING and left_value != right_value:
                raise MergeConflict(f"{key}: conflicting addition {entry_key}")
            selected[entry_key] = "ours" if left is not MISSING else "theirs"
        elif left is MISSING or right is MISSING:
            if left is MISSING and right is MISSING:
                continue
            survivor = right_value if left is MISSING else left_value
            if survivor == old_value:
                continue
            raise MergeConflict(f"{key}: removal conflicts with edit {entry_key}")
        elif left_value == right_value or left_value == old_value:
            selected[entry_key] = "ours" if left_value == right_value else "theirs"
        elif right_value == old_value:
            selected[entry_key] = "ours"
        else:
            raise MergeConflict(f"{key}: conflicting edits to {entry_key}")

    raw_by_side = {
        side: {entry["key"]: source_doc.raw_member(entry)
               for entry in entries(source_doc, source_member)}
        for side, source_doc, source_member in (
            ("ours", ours_doc, ours_member),
            ("theirs", theirs_doc, theirs_member),
        )
    }
    output_entries = [raw_by_side[selected[entry_key]][entry_key]
                      for entry_key in order if entry_key in selected]
    chosen_doc = ours_doc if ours_member is not None else theirs_doc
    chosen_member = ours_member if ours_member is not None else theirs_member
    source_entries, open_end, close_start = chosen_doc.object_members(chosen_member["value_start"])
    if source_entries:
        prefix = chosen_doc.text[open_end:source_entries[0]["key_start"]]
        suffix = chosen_doc.text[source_entries[-1]["value_end"]:close_start]
    else:
        prefix = chosen_doc.text[open_end:close_start]
        suffix = ""
    separator = ""
    for candidate_doc, candidate_member in ((ours_doc, ours_member), (theirs_doc, theirs_member)):
        if candidate_doc is None or candidate_member is None:
            continue
        candidate_entries = candidate_doc.object_members(candidate_member["value_start"])[0]
        if len(candidate_entries) > 1:
            separator = candidate_doc.text[candidate_entries[0]["value_end"]:candidate_entries[1]["key_start"]]
            break
    if not separator:
        separator = ","
    return "{" + prefix + separator.join(output_entries) + suffix + "}"


def merge_documents(base_doc, ours_doc, theirs_doc):
    base_members = base_doc.members_by_key
    ours_members = ours_doc.members_by_key
    theirs_members = theirs_doc.members_by_key
    keys = [member["key"] for member in ours_doc.members]
    keys.extend(member["key"] for member in theirs_doc.members if member["key"] not in ours_members)
    result_members = []
    for key in keys:
        base_member = base_members.get(key)
        ours_member = ours_members.get(key)
        theirs_member = theirs_members.get(key)
        old = base_member["value"] if base_member else MISSING
        left = ours_member["value"] if ours_member else MISSING
        right = theirs_member["value"] if theirs_member else MISSING
        if left == right:
            chosen_side = "ours"
            chosen_value = left
        elif left == old:
            chosen_side = "theirs"
            chosen_value = right
        elif right == old:
            chosen_side = "ours"
            chosen_value = left
        elif all(value is not MISSING and isinstance(value, list) for value in (left, right)):
            array_raw = merge_array(base_doc, ours_doc, theirs_doc, key, base_member, ours_member, theirs_member)
            result_members.append(ours_doc.raw_member(ours_member, array_raw))
            continue
        elif all(value is not MISSING and isinstance(value, dict) for value in (left, right)):
            object_raw = merge_object_map(base_doc, ours_doc, theirs_doc, key, base_member, ours_member, theirs_member)
            result_members.append(ours_doc.raw_member(ours_member, object_raw))
            continue
        else:
            raise MergeConflict(f"conflicting top-level value {key}")
        if chosen_value is MISSING:
            continue
        source_doc = ours_doc if chosen_side == "ours" else theirs_doc
        source_member = ours_member if chosen_side == "ours" else theirs_member
        if source_member is None:
            continue
        if ours_member is not None:
            result_members.append(ours_doc.raw_member(ours_member, source_doc.raw_value(source_member)))
        else:
            result_members.append(source_doc.raw_member(source_member))

    layout_doc = ours_doc if ours_doc.members else theirs_doc
    layout_members = layout_doc.members
    if layout_members:
        prefix = layout_doc.text[layout_doc.open_end:layout_members[0]["key_start"]]
        suffix = layout_doc.text[layout_members[-1]["value_end"]:layout_doc.close_start]
        separator = ""
        if len(layout_members) > 1:
            separator = layout_doc.text[layout_members[0]["value_end"]:layout_members[1]["key_start"]]
        if not separator:
            separator = ","
    else:
        prefix = layout_doc.text[layout_doc.open_end:layout_doc.close_start]
        suffix = ""
        separator = ","
    merged = layout_doc.text[:layout_doc.open_end] + prefix + separator.join(result_members) + suffix + layout_doc.text[layout_doc.close_start:]
    json.loads(merged)
    return merged


base_doc, ours_doc, theirs_doc = (Document(path) for path in sys.argv[1:4])
for doc in (base_doc, ours_doc, theirs_doc):
    doc.members_by_key = {member["key"]: member for member in doc.members}
try:
    output = merge_documents(base_doc, ours_doc, theirs_doc)
except MergeConflict as error:
    print(f"git-merge-state-json: {error}", file=sys.stderr)
    raise SystemExit(1)

target = sys.argv[2]
mode = stat.S_IMODE(os.stat(target).st_mode)
fd, temp_path = tempfile.mkstemp(prefix=".state-json-merge.", dir=os.path.dirname(os.path.abspath(target)))
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
        stream.write(output)
    os.chmod(temp_path, mode)
    os.replace(temp_path, target)
except Exception:
    try:
        os.unlink(temp_path)
    except FileNotFoundError:
        pass
    raise
PY
