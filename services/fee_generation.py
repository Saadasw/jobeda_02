"""
Bulk fee generation.

Turns fee structures (or a manual flat charge) into fee_assignment rows for
every active student in scope, skipping any that already exist for the month.
The existing UNIQUE (tenant, student, fee_type, month) constraint is the race
backstop; we pre-check to report accurate created/skipped counts and to power
the dry-run preview.
"""
from collections import defaultdict
from decimal import Decimal
from typing import List, Optional

from database import supabase


def _chunks(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def _month_first(month: str) -> str:
    """Normalize any 'YYYY-MM-DD' (or 'YYYY-MM') to the 1st of that month."""
    return month[:7] + "-01"


def _due_date(month_first: str, due_day: Optional[int]) -> Optional[str]:
    if not due_day:
        return None
    return f"{month_first[:7]}-{int(due_day):02d}"


def _active_enrollments(tenant_id, year_id, class_id=None, section_id=None):
    q = (
        supabase.table("student_enrollments").select("student_id, class_id")
        .eq("tenant_id", tenant_id).eq("academic_year_id", year_id).eq("status", "active")
    )
    if class_id:
        q = q.eq("class_id", class_id)
    if section_id:
        q = q.eq("section_id", section_id)
    return q.execute().data


def _live_student_groups(tenant_id, student_ids):
    """{student_id: fee_group_id} for non-deleted students only."""
    if not student_ids:
        return {}
    rows = (
        supabase.table("students").select("id, fee_group_id")
        .eq("tenant_id", tenant_id).in_("id", student_ids).eq("is_deleted", False)
        .execute().data
    )
    return {r["id"]: r.get("fee_group_id") for r in rows}


def bulk_assign(tenant_id, month_first, rows, created_by_id=None, dry_run=False):
    """
    rows: list of {student_id, fee_type_id, amount, account_id, due_date}.
    Skips any (student, fee_type) that already has a row for month_first
    (regardless of is_deleted — matches the non-partial unique constraint).
    """
    result = {"created": 0, "skipped": 0, "no_structure": 0,
              "students_in_scope": len({r["student_id"] for r in rows}),
              "total_amount": 0.0, "month": month_first}
    if not rows:
        return result

    student_ids = list({r["student_id"] for r in rows})
    fee_type_ids = list({r["fee_type_id"] for r in rows})

    existing = (
        supabase.table("fee_assignments").select("student_id, fee_type_id")
        .eq("tenant_id", tenant_id).eq("month", month_first)
        .in_("student_id", student_ids).in_("fee_type_id", fee_type_ids)
        .execute().data
    )
    have = {(e["student_id"], e["fee_type_id"]) for e in existing}

    to_create = [r for r in rows if (r["student_id"], r["fee_type_id"]) not in have]
    result["skipped"] = len(rows) - len(to_create)
    result["total_amount"] = float(sum(Decimal(str(r["amount"])) for r in to_create))

    if dry_run:
        result["created"] = len(to_create)
        return result

    inserted = 0
    for chunk in _chunks(to_create, 200):
        payload = []
        for r in chunk:
            row = {
                "tenant_id": tenant_id,
                "student_id": r["student_id"],
                "fee_type_id": r["fee_type_id"],
                "month": month_first,
                "amount": float(r["amount"]),
                "account_id": r["account_id"],
            }
            if r.get("due_date"):
                row["due_date"] = r["due_date"]
            if created_by_id is not None:
                row["created_by_id"] = created_by_id
            payload.append(row)
        inserted += len(supabase.table("fee_assignments").insert(payload).execute().data)
    result["created"] = inserted
    return result


def generate_from_structures(tenant_id, year_id, month, *, class_id=None,
                             section_id=None, fee_type_ids=None,
                             created_by_id=None, dry_run=False):
    """Bill each active student per their (class, fee_group) structure."""
    month_first = _month_first(month)

    enrollments = _active_enrollments(tenant_id, year_id, class_id, section_id)
    group_map = _live_student_groups(tenant_id, [e["student_id"] for e in enrollments])
    enrollments = [e for e in enrollments if e["student_id"] in group_map]  # drop deleted

    # Structures for the year (optionally one class) + their live items.
    sq = (
        supabase.table("fee_structures").select("id, class_id, fee_group_id")
        .eq("tenant_id", tenant_id).eq("academic_year_id", year_id).eq("is_deleted", False)
    )
    if class_id:
        sq = sq.eq("class_id", class_id)
    structures = sq.execute().data
    struct_id_by_key = {(s["class_id"], s["fee_group_id"]): s["id"] for s in structures}
    struct_ids = [s["id"] for s in structures]

    items_by_struct = defaultdict(list)
    needed_types = set()
    if struct_ids:
        for it in (supabase.table("fee_structure_items").select("*")
                   .in_("fee_structure_id", struct_ids).eq("is_deleted", False)
                   .execute().data):
            if fee_type_ids is not None:
                if it["fee_type_id"] not in fee_type_ids:
                    continue
            elif it.get("frequency") != "monthly":
                continue
            if Decimal(str(it["amount"])) <= 0:
                continue
            items_by_struct[it["fee_structure_id"]].append(it)
            needed_types.add(it["fee_type_id"])

    acct_map = {}
    if needed_types:
        acct_map = {
            f["id"]: f["account_id"]
            for f in (supabase.table("fee_types").select("id, account_id")
                      .eq("tenant_id", tenant_id).in_("id", list(needed_types)).execute().data)
        }

    rows = []
    no_structure = 0
    for e in enrollments:
        sid = e["student_id"]
        struct_id = struct_id_by_key.get((e["class_id"], group_map.get(sid)))
        items = items_by_struct.get(struct_id) if struct_id else None
        if not items:
            no_structure += 1
            continue
        for it in items:
            acct = acct_map.get(it["fee_type_id"])
            if acct is None:
                continue
            rows.append({
                "student_id": sid,
                "fee_type_id": it["fee_type_id"],
                "amount": it["amount"],
                "account_id": acct,
                "due_date": _due_date(month_first, it.get("due_day")),
            })

    res = bulk_assign(tenant_id, month_first, rows, created_by_id, dry_run)
    res["no_structure"] = no_structure
    res["students_in_scope"] = len(enrollments)
    return res


def generate_manual(tenant_id, year_id, month, *, fee_type_id, amount,
                    class_id=None, section_id=None, due_day=None,
                    created_by_id=None, dry_run=False):
    """Flat charge of one fee type to every active student in scope (no structure)."""
    month_first = _month_first(month)

    ft = (supabase.table("fee_types").select("id, account_id")
          .eq("tenant_id", tenant_id).eq("id", fee_type_id).eq("is_deleted", False)
          .execute().data)
    if not ft:
        raise ValueError("Fee type not found")
    account_id = ft[0]["account_id"]

    enrollments = _active_enrollments(tenant_id, year_id, class_id, section_id)
    live = _live_student_groups(tenant_id, [e["student_id"] for e in enrollments])
    enrollments = [e for e in enrollments if e["student_id"] in live]

    due = _due_date(month_first, due_day)
    rows = [{
        "student_id": e["student_id"],
        "fee_type_id": fee_type_id,
        "amount": amount,
        "account_id": account_id,
        "due_date": due,
    } for e in enrollments]

    res = bulk_assign(tenant_id, month_first, rows, created_by_id, dry_run)
    res["students_in_scope"] = len(enrollments)
    return res
