#!/usr/bin/env python3
"""Browser test of the Atlas Service Desk UI (Playwright, Chromium, headless).

Creates a ticket through the form, changes its status on the detail page, reloads
and checks the saved status. Also checks the environment banner and version footer.
The target URL is never printed. Screenshots go to --screenshots (optional).

Exit codes: 0 pass, 3 wrong result in the UI, 2 environment problem.
Usage: ui_check.py --base-url URL [--label TEXT] [--expect-expiry] [--screenshots DIR]
"""
import argparse
import os
import sys

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import TimeoutError as PlaywrightTimeout
from playwright.sync_api import expect, sync_playwright

TARGET_STATUS = "In progress"


def run(page, base, label, expect_expiry, shots):
    def shot(name):
        if shots:
            page.screenshot(path=os.path.join(shots, f"{name}.png"), full_page=True)

    page.goto(base + "/", wait_until="networkidle")
    expect(page.get_by_test_id("ticket-table")).to_be_visible()
    banner = page.get_by_test_id("env-banner")
    expect(banner).not_to_contain_text("Loading")
    if expect_expiry:
        expect(banner).to_contain_text("Planned expiry")
        expect(banner).to_contain_text("stops working")
    expect(page.get_by_test_id("version")).to_contain_text("Image ")
    print("PASS: list page, environment banner and version footer shown")
    shot("01-list")

    title = f"{label} browser check"
    page.get_by_test_id("new-ticket-link").click()
    page.get_by_test_id("title").fill(title)
    page.get_by_test_id("requester").fill("Browser Check (fictional)")
    page.get_by_test_id("priority").select_option("Critical")
    page.get_by_test_id("description").fill("Created by the automated browser test. Fictional data.")
    shot("02-new-form")
    page.get_by_test_id("create-ticket").click()
    expect(page.get_by_test_id("detail-title")).to_have_text(title)
    expect(page.get_by_test_id("detail-status")).to_have_text("Open")
    expect(page.get_by_test_id("detail-priority")).to_have_text("Critical")
    print("PASS: ticket created through the form (Open, Critical)")

    page.get_by_test_id("update-status").select_option(TARGET_STATUS)
    page.get_by_test_id("save-ticket").click()
    expect(page.get_by_test_id("save-message")).to_have_text("Saved.")
    page.reload(wait_until="networkidle")
    actual = page.get_by_test_id("detail-status").inner_text(timeout=10000)
    if actual != TARGET_STATUS:
        shot("03-detail-wrong")
        raise AssertionError(f"status mismatch after reload: expected {TARGET_STATUS!r}, got {actual!r}")
    expect(page.get_by_test_id("history")).to_contain_text(f"status: Open → {TARGET_STATUS}")
    print(f"PASS: status shows {TARGET_STATUS!r} after reload, and history records it")
    shot("03-detail")

    page.goto(base + "/#/?status=In%20progress", wait_until="networkidle")
    expect(page.get_by_test_id("ticket-table")).to_contain_text(title)
    print("PASS: ticket listed under the 'In progress' filter")


def redact(error, base):
    """First line of an error, with the target address replaced."""
    line = (str(error).splitlines() or [""])[0]
    return line.replace(base.rstrip("/"), "<target>")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--label", default="CI-TEST")
    parser.add_argument("--expect-expiry", action="store_true")
    parser.add_argument("--screenshots")
    args = parser.parse_args()
    if args.screenshots:
        os.makedirs(args.screenshots, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 860})
        page.set_default_timeout(15000)
        try:
            run(page, args.base_url.rstrip("/"), args.label, args.expect_expiry, args.screenshots)
        except AssertionError as e:
            print(f"FAIL: {redact(e, args.base_url)}")
            return 3
        except (PlaywrightTimeout, PlaywrightError) as e:
            print(f"ERROR: browser step failed: {redact(e, args.base_url)}")
            return 2
        finally:
            browser.close()
    print("RESULT: browser check PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
