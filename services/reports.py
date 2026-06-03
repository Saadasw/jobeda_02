"""
Report query service.
Contains the SQL-like query logic for financial reports using Supabase.
Every query is scoped to a single tenant via tenant_id.
"""
from decimal import Decimal
from typing import Optional
from database import supabase


def get_trial_balance(
    tenant_id: str,
    from_date: Optional[str] = None,
    to_date: Optional[str] = None,
) -> dict:
    """Compute trial balance by aggregating journal lines for one tenant."""
    # Get all journal entries (with optional date filter)
    je_query = (
        supabase.table("journal_entries")
        .select("id, date")
        .eq("tenant_id", tenant_id)
        .eq("is_reversed", False)
    )
    if from_date:
        je_query = je_query.gte("date", from_date)
    if to_date:
        je_query = je_query.lte("date", to_date)
    je_resp = je_query.execute()
    journal_ids = [je["id"] for je in je_resp.data]

    if not journal_ids:
        return {"lines": [], "total_debit": 0, "total_credit": 0}

    # Get all journal lines for those entries (tenant-scoped)
    lines_resp = (
        supabase.table("journal_lines")
        .select("account_id, debit, credit")
        .eq("tenant_id", tenant_id)
        .in_("journal_id", journal_ids)
        .execute()
    )

    # Get accounts
    accounts_resp = (
        supabase.table("accounts")
        .select("id, name, type")
        .eq("tenant_id", tenant_id)
        .eq("is_deleted", False)
        .execute()
    )
    accounts_map = {a["id"]: a for a in accounts_resp.data}

    # Aggregate by account
    aggregated = {}
    for line in lines_resp.data:
        aid = line["account_id"]
        if aid not in aggregated:
            aggregated[aid] = {"total_debit": Decimal("0"), "total_credit": Decimal("0")}
        aggregated[aid]["total_debit"] += Decimal(str(line["debit"]))
        aggregated[aid]["total_credit"] += Decimal(str(line["credit"]))

    result_lines = []
    total_debit = Decimal("0")
    total_credit = Decimal("0")
    for aid, totals in aggregated.items():
        acct = accounts_map.get(aid, {"name": "Unknown", "type": "unknown"})
        balance = totals["total_debit"] - totals["total_credit"]
        result_lines.append({
            "account_id": aid,
            "account_name": acct["name"],
            "account_type": acct["type"],
            "total_debit": float(totals["total_debit"]),
            "total_credit": float(totals["total_credit"]),
            "balance": float(balance),
        })
        total_debit += totals["total_debit"]
        total_credit += totals["total_credit"]

    return {
        "lines": result_lines,
        "total_debit": float(total_debit),
        "total_credit": float(total_credit),
    }


def get_income_statement(
    tenant_id: str,
    from_date: Optional[str] = None,
    to_date: Optional[str] = None,
) -> dict:
    """Income statement: revenue vs expenses."""
    tb = get_trial_balance(tenant_id, from_date, to_date)

    revenue = [l for l in tb["lines"] if l["account_type"] == "revenue"]
    expenses = [l for l in tb["lines"] if l["account_type"] == "expense"]

    total_revenue = sum(Decimal(str(l["total_credit"])) - Decimal(str(l["total_debit"])) for l in revenue)
    total_expenses = sum(Decimal(str(l["total_debit"])) - Decimal(str(l["total_credit"])) for l in expenses)

    return {
        "revenue": revenue,
        "expenses": expenses,
        "total_revenue": float(total_revenue),
        "total_expenses": float(total_expenses),
        "net_income": float(total_revenue - total_expenses),
    }


def get_balance_sheet(
    tenant_id: str,
    from_date: Optional[str] = None,
    to_date: Optional[str] = None,
) -> dict:
    """Balance sheet: Assets = Liabilities + Equity."""
    tb = get_trial_balance(tenant_id, from_date, to_date)

    assets = [l for l in tb["lines"] if l["account_type"] == "asset"]
    liabilities = [l for l in tb["lines"] if l["account_type"] == "liability"]
    equity = [l for l in tb["lines"] if l["account_type"] == "equity"]

    total_assets = sum(Decimal(str(l["balance"])) for l in assets)
    total_liabilities = sum(Decimal(str(abs(l["balance"]))) for l in liabilities)
    total_equity = sum(Decimal(str(abs(l["balance"]))) for l in equity)

    return {
        "assets": assets,
        "liabilities": liabilities,
        "equity": equity,
        "total_assets": float(total_assets),
        "total_liabilities": float(total_liabilities),
        "total_equity": float(total_equity),
    }
