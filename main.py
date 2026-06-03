"""
Jobeda Madrasa ERP — FastAPI Application
Main entry point. Registers all route modules.
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routes import auth, academic, students, employees, accounts
from routes import fees, payments, salary, expenses, income
from routes import reports, journal
from routes import tenants, roles, users
from routes import discounts, payroll, exams, attendance
from routes import accounting_reports, notifications

app = FastAPI(
    title="Jobeda Madrasa ERP API",
    description=(
        "Industry-grade Madrasa management system with double-entry accounting.\n\n"
        "**Modules:** Students, Employees, Fees, Payments, Salary, Expenses, "
        "Income, Accounts, Reports, Journal.\n\n"
        "All financial transactions automatically generate journal entries via DB triggers."
    ),
    version="2.0.0",
)

# CORS — allow all origins during development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Register Routers ────────────────────────────────────────────────────────

# Identity & tenancy
app.include_router(auth.router)
app.include_router(tenants.router)
app.include_router(roles.router)
app.include_router(users.router)

# Academic & people
app.include_router(academic.router)
app.include_router(students.router)
app.include_router(employees.router)

# Accounting & reports
app.include_router(accounts.router)
app.include_router(journal.router)
app.include_router(reports.router)
app.include_router(accounting_reports.router)

# Fees, payments & discounts
app.include_router(fees.router)
app.include_router(payments.router)
app.include_router(discounts.router)

# Payroll
app.include_router(salary.router)
app.include_router(payroll.router)

# Expenses & income
app.include_router(expenses.router)
app.include_router(income.router)

# Exams & attendance
app.include_router(exams.router)
app.include_router(attendance.router)

# Notifications
app.include_router(notifications.router)


@app.get("/", tags=["Root"])
def read_root():
    """API health check and welcome message."""
    return {
        "message": "Jobeda Madrasa ERP API v2.0",
        "docs": "/docs",
        "modules": [
            "auth", "tenants", "roles", "users",
            "academic", "students", "employees",
            "accounts", "journal", "reports", "accounting_reports",
            "fees", "payments", "discounts",
            "salary", "payroll",
            "expenses", "income",
            "exams", "attendance",
            "notifications",
        ],
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)
