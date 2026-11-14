#!/usr/bin/env python3
"""
Amazon A to Z Schedule Manager
Authenticates via browser and interacts with the ScheduleManagementAssociateGateway GraphQL API.

Requirements:
    pip install selenium requests

Usage:
    python amazon_scheduler.py
"""

import json
import os
import base64
import time
import sys
from datetime import datetime, timezone, timedelta

try:
    import requests
except ImportError:
    print("Missing dependency: pip install requests")
    sys.exit(1)

try:
    from selenium import webdriver
    from selenium.webdriver.firefox.options import Options as FirefoxOptions
    from selenium.webdriver.chrome.options import Options as ChromeOptions
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.common.exceptions import TimeoutException
except ImportError:
    print("Missing dependency: pip install selenium")
    sys.exit(1)

# ── Config ────────────────────────────────────────────────────────────────────
EMPLOYEE_ID   = "204193941"
ENDPOINT      = f"https://atoz-apps.amazon.work/apis/ScheduleManagementAssociateGateway/graphql?employeeId={EMPLOYEE_ID}"
LOGIN_URL     = "https://atoz.amazon.work"
COOKIE_FILE   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cookies.json")
AUTH_DOMAIN   = "atoz-apps.amazon.work"
LOGIN_DOMAIN  = "atoz.amazon.work"

HEADERS = {
    "content-type":            "application/json",
    "x-atoz-client-id":        "SCHEDULE_MANAGEMENT_SERVICE",
    "Origin":                  "https://atoz.amazon.work",
    "Referer":                 "https://atoz.amazon.work/",
    "User-Agent":              "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:159.0) Gecko/20100101 Firefox/159.0",
    "Accept":                  "*/*",
    "Accept-Language":         "en-US,en;q=0.9",
}

# ── JWT helpers ───────────────────────────────────────────────────────────────
def decode_jwt_payload(token: str) -> dict | None:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        padding = 4 - len(parts[1]) % 4
        payload = parts[1] + "=" * padding
        payload = payload.replace("-", "+").replace("_", "/")
        return json.loads(base64.b64decode(payload).decode("utf-8"))
    except Exception:
        return None

def is_token_expired(token: str, buffer_seconds: int = 60) -> bool:
    payload = decode_jwt_payload(token)
    if not payload or "exp" not in payload:
        return True
    now = int(datetime.now(timezone.utc).timestamp())
    return payload["exp"] < (now + buffer_seconds)

def token_expires_in(token: str) -> int:
    payload = decode_jwt_payload(token)
    if not payload or "exp" not in payload:
        return 0
    now = int(datetime.now(timezone.utc).timestamp())
    return max(0, payload["exp"] - now)

# ── Cookie persistence ────────────────────────────────────────────────────────
def save_cookies(cookies: dict):
    with open(COOKIE_FILE, "w") as f:
        json.dump(cookies, f, indent=2)
    print(f"✅ Cookies saved to {COOKIE_FILE}")

def load_cookies() -> dict | None:
    if not os.path.exists(COOKIE_FILE):
        return None
    try:
        with open(COOKIE_FILE) as f:
            return json.load(f)
    except Exception:
        return None

def cookies_are_valid(cookies: dict) -> bool:
    token = cookies.get("atoz-oauth-token")
    if not token:
        return False
    return not is_token_expired(token)

def cookies_to_header(cookies: dict) -> str:
    return "; ".join(f"{k}={v}" for k, v in cookies.items())

# ── Browser authentication ────────────────────────────────────────────────────
def authenticate_via_browser() -> dict:
    """Opens browser, waits for user to log in, extracts cookies."""
    print("\n🌐 Opening browser for authentication...")
    print(f"   Please log in at: {LOGIN_URL}")
    print("   The script will continue automatically once you're logged in.\n")

    driver = None

    # Try Firefox first, then Chrome
    for browser in ["firefox", "chrome"]:
        try:
            if browser == "firefox":
                opts = FirefoxOptions()
                # Non-headless so user can interact
                driver = webdriver.Firefox(options=opts)
            else:
                opts = ChromeOptions()
                driver = webdriver.Chrome(options=opts)
            print(f"   Using {browser.capitalize()}")
            break
        except Exception as e:
            print(f"   {browser.capitalize()} not available: {e}")
            continue

    if driver is None:
        print("❌ Could not launch Firefox or Chrome. Please install one and its WebDriver.")
        print("   Firefox: https://github.com/mozilla/geckodriver/releases")
        print("   Chrome:  https://chromedriver.chromium.org/downloads")
        sys.exit(1)

    try:
        driver.get(LOGIN_URL)

        print("⏳ Waiting for you to log in (timeout: 3 minutes)...")
        timeout = 180  # 3 minutes

        def has_auth_token(d):
            for cookie in d.get_cookies():
                if cookie["name"] == "atoz-oauth-token":
                    return True
            return False

        WebDriverWait(driver, timeout).until(has_auth_token)
        print("✅ Login detected! Extracting cookies...")

        # Small wait to let all cookies settle
        time.sleep(2)

        # Collect cookies from both domains
        all_cookies = {}

        # Get cookies from current domain (atoz.amazon.work)
        for cookie in driver.get_cookies():
            all_cookies[cookie["name"]] = cookie["value"]

        # Navigate to the API domain to get its cookies too
        try:
            driver.get(f"https://{AUTH_DOMAIN}")
            time.sleep(1)
            for cookie in driver.get_cookies():
                all_cookies[cookie["name"]] = cookie["value"]
        except Exception:
            pass

        return all_cookies

    except TimeoutException:
        print("❌ Login timed out after 3 minutes.")
        sys.exit(1)
    finally:
        driver.quit()

def get_cookies() -> dict:
    """Load saved cookies if valid, otherwise re-authenticate."""
    cookies = load_cookies()
    if cookies and cookies_are_valid(cookies):
        secs = token_expires_in(cookies.get("atoz-oauth-token", ""))
        print(f"✅ Using saved session (expires in {secs // 60}m {secs % 60}s)")
        return cookies

    print("🔑 No valid session found. Starting browser authentication...")
    cookies = authenticate_via_browser()
    save_cookies(cookies)
    return cookies

# ── GraphQL requests ──────────────────────────────────────────────────────────
def get_find_shifts_query() -> str:
    """Loads the complete FindShiftsPageMore query from AtoZGraphQL.swift."""
    swift_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Gemma", "Gemma", "AtoZ", "AtoZGraphQL.swift")
    if os.path.exists(swift_file):
        try:
            with open(swift_file, "r", encoding="utf-8") as f:
                content = f.read()
            marker = 'static let findShiftsMoreQuery = #"""'
            start_idx = content.find(marker)
            if start_idx != -1:
                start_idx += len(marker)
                end_idx = content.find('"""#', start_idx)
                if end_idx != -1:
                    return content[start_idx:end_idx].strip()
        except Exception as e:
            print(f"⚠️ Could not read query from {swift_file}: {e}")
    raise RuntimeError("FindShiftsPageMore query not found in AtoZGraphQL.swift")

def graphql_request(cookies: dict, body: dict) -> dict:
    headers = {**HEADERS, "Cookie": cookies_to_header(cookies)}
    resp = requests.post(ENDPOINT, headers=headers, json=body, timeout=30)
    try:
        data = resp.json()
    except Exception:
        resp.raise_for_status()
        return {}

    if resp.status_code != 200:
        if "errors" in data:
            print(f"❌ Server returned {resp.status_code}: {data['errors']}")
        else:
            print(f"❌ Server returned {resp.status_code}: {data.get('message', resp.text)}")
    return data

def get_schedule(cookies: dict):
    """Fetch upcoming scheduled shifts."""
    now = datetime.now(timezone.utc)
    # Start from this Monday 05:00 UTC
    monday = now - timedelta(days=now.weekday())
    start = monday.replace(hour=5, minute=0, second=0, microsecond=0)
    end   = start + timedelta(weeks=8) - timedelta(seconds=1)

    body = {
        "operationName": "GetSchedule",
        "variables": {
            "canFetchPayBreakdown": True,
            "scheduleTimeRange": {
                "start": start.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                "end":   end.strftime("%Y-%m-%dT%H:%M:%S.999Z"),
            }
        },
        "query": (
            "query GetSchedule($scheduleTimeRange: DateTimeRangeInput!, $canFetchPayBreakdown: Boolean = false) {\n"
            "  schedule(timeRange: $scheduleTimeRange) {\n"
            "    scheduleShifts {\n"
            "      shift {\n"
            "        id\n"
            "        timeRange { start end __typename }\n"
            "        site { name __typename }\n"
            "        __typename\n"
            "      }\n"
            "      skill\n"
            "      payBreakdown @include(if: $canFetchPayBreakdown) {\n"
            "        summary {\n"
            "          duration { value __typename }\n"
            "          totalShiftPayRange { max { amount code __typename } __typename }\n"
            "          __typename\n"
            "        }\n"
            "        __typename\n"
            "      }\n"
            "      __typename\n"
            "    }\n"
            "    __typename\n"
            "  }\n"
            "}"
        )
    }

    data = graphql_request(cookies, body)
    shifts = data.get("data", {}).get("schedule", {}).get("scheduleShifts", [])

    if not shifts:
        print("\n📅 No upcoming shifts found.")
        return

    print(f"\n📅 Upcoming Shifts ({len(shifts)} total):")
    print("-" * 65)
    for s in shifts:
        shift    = s.get("shift", {})
        tr       = shift.get("timeRange", {})
        site     = shift.get("site", {}).get("name", "?")
        skill    = s.get("skill", "?")
        start_dt = datetime.fromisoformat(tr["start"].replace("Z", "+00:00"))
        end_dt   = datetime.fromisoformat(tr["end"].replace("Z", "+00:00"))
        duration = end_dt - start_dt
        hours    = duration.seconds // 3600
        mins     = (duration.seconds % 3600) // 60

        pay = ""
        pb  = s.get("payBreakdown")
        if pb:
            amt = pb.get("summary", {}).get("totalShiftPayRange", {}).get("max", {}).get("amount")
            if amt:
                pay = f"  💵 ${amt:.0f}"

        print(f"  {start_dt.strftime('%a %b %d')}  {start_dt.strftime('%I:%M %p')} – {end_dt.strftime('%I:%M %p')}  ({hours}h {mins}m)  [{site}] {skill}{pay}")
    print("-" * 65)

def get_available_shifts(cookies: dict):
    """Fetch available shift opportunities."""
    now   = datetime.now(timezone.utc)
    start = now.replace(hour=5, minute=0, second=0, microsecond=0)
    end   = start + timedelta(days=14)

    query = get_find_shifts_query()

    body = {
        "operationName": "FindShiftsPageMore",
        "variables": {
            "canFetchPayBreakdown": True,
            "canFetchInterestList": False,
            "filter": {
                "includeIneligible": True,
                "unavailableReasonsToInclude": [
                    "AssociateAccepted",
                    "ShiftOpportunityCapacityMet",
                    "ShiftOpportunityExpired"
                ]
            },
            "timeRange": {
                "start": start.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                "end":   end.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            },
            "opportunityTypes": {
                "types": ["DROP", "VOLUNTARY_TIME_OFF", "ADD", "VOLUNTARY_EXTRA_TIME"]
            }
        },
        "query": query
    }

    data = graphql_request(cookies, body)
    if not data or "errors" in data and not data.get("data"):
        print("\n❌ Could not retrieve shifts from Amazon A to Z.")
        return

    data_section = data.get("data") or {}
    shift_opps = data_section.get("shiftOpportunities") or {}
    opps = shift_opps.get("opportunities") or []

    eligible = [o for o in opps if (o.get("eligibility") or {}).get("isEligible")]

    if not eligible:
        print(f"\n🔍 No available shifts found for the next 14 days ({len(opps)} total opportunities, none eligible).")
        return

    print(f"\n🔍 Available Shifts ({len(eligible)} eligible found out of {len(opps)} total):")
    print("-" * 75)
    for i, o in enumerate(eligible, 1):
        shift    = o.get("shift") or {}
        tr       = shift.get("timeRange") or {}
        site     = (shift.get("site") or {}).get("name", "?")
        skill    = o.get("skill", "?")
        opp_id   = o.get("id", "?")
        opp_type = o.get("type", "?")
        start_raw = tr.get("start")
        end_raw   = tr.get("end")

        if start_raw and end_raw:
            start_dt = datetime.fromisoformat(start_raw.replace("Z", "+00:00"))
            end_dt   = datetime.fromisoformat(end_raw.replace("Z", "+00:00"))
            duration = end_dt - start_dt
            hours    = duration.seconds // 3600
            mins     = (duration.seconds % 3600) // 60
            time_str = f"{start_dt.strftime('%a %b %d')}  {start_dt.strftime('%I:%M %p')} – {end_dt.strftime('%I:%M %p')}  ({hours}h {mins}m)"
        else:
            time_str = "Time range unavailable"

        pay = ""
        pb  = o.get("payBreakdown")
        if pb:
            summary = pb.get("summary") or {}
            total_pay = summary.get("totalShiftPayRange") or {}
            max_pay = total_pay.get("max") or {}
            amt = max_pay.get("amount")
            if amt is not None:
                pay = f"  💵 ${amt:.0f}"

        print(f"  [{i}] {time_str}  [{site}] {skill}  ({opp_type}){pay}")
        print(f"      ID: {opp_id}")
    print("-" * 75)

def add_shift(cookies: dict, opportunity_id: str):
    """Claim a shift opportunity by ID."""
    body = {
        "operationName": "AddShift",
        "variables": {
            "shiftOpportunityId": {
                "shiftOpportunityId": opportunity_id
            }
        },
        "query": "mutation AddShift($shiftOpportunityId: AddShiftInput!) {\n  addShift(input: $shiftOpportunityId)\n}"
    }

    print(f"\n⏳ Claiming shift: {opportunity_id}")
    data = graphql_request(cookies, body)

    if "errors" in data:
        print(f"❌ Error: {data['errors']}")
    else:
        result = data.get("data", {}).get("addShift")
        print(f"✅ Success! Result: {result}")

def copy_cookies_to_clipboard(cookies: dict):
    header = cookies_to_header(cookies)
    try:
        import subprocess
        process = subprocess.Popen('pbcopy', env={'LANG': 'en_US.UTF-8'}, stdin=subprocess.PIPE)
        process.communicate(header.encode('utf-8'))
        print("✅ Cookies copied to clipboard! Open Gemma and tap 'Pegar del Portapapeles'.")
    except Exception as e:
        print(f"⚠️ Could not copy to clipboard: {e}")

# ── CLI menu ──────────────────────────────────────────────────────────────────
def main():
    print("=" * 55)
    print("  Amazon A to Z — Schedule Manager")
    print("=" * 55)

    cookies = get_cookies()

    while True:
        print("\nWhat would you like to do?")
        print("  1. View my schedule")
        print("  2. View available shifts")
        print("  3. Add a shift (by opportunity ID)")
        print("  4. Re-authenticate (refresh session via browser)")
        print("  5. Copy session to clipboard (for Gemma agent app)")
        print("  6. Exit")

        choice = input("\nEnter choice [1-6]: ").strip()

        if choice == "1":
            get_schedule(cookies)

        elif choice == "2":
            get_available_shifts(cookies)

        elif choice == "3":
            opp_id = input("Enter opportunity ID: ").strip()
            if opp_id:
                confirm = input(f"⚠️  Confirm adding shift {opp_id}? (yes/no): ").strip().lower()
                if confirm == "yes":
                    add_shift(cookies, opp_id)
                else:
                    print("Cancelled.")
            else:
                print("No ID entered.")

        elif choice == "4":
            print("🔄 Re-authenticating...")
            cookies = authenticate_via_browser()
            save_cookies(cookies)

        elif choice == "5":
            copy_cookies_to_clipboard(cookies)

        elif choice == "6":
            print("👋 Bye!")
            break

        else:
            print("Invalid choice. Please enter 1-6.")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--auth-only":
        print("Starting browser authentication for Gemma...")
        cookies = authenticate_via_browser()
        save_cookies(cookies)
        copy_cookies_to_clipboard(cookies)
        print("GEMMA_COOKIES_START")
        print(json.dumps(cookies))
        print("GEMMA_COOKIES_END")
        sys.exit(0)
    main()
