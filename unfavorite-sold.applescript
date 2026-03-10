-- =============================================================================
-- Vinted Sold-Favorites Cleanup Script
-- Unfavorites sold items from your Vinted favorites page automatically.
--
-- Prerequisites:
--   - macOS Accessibility permissions for Script Editor / osascript
--   - Logged into Vinted in Google Chrome
--   - Chrome is open
-- =============================================================================

-- ─── Configuration ───────────────────────────────────────────────────────────
-- Change this to your Vinted favorites URL (your country domain may differ)
property FAVORITES_URL : "https://www.vinted.com/member/items/favourites"

-- DOM selectors — adjust if Vinted changes their markup
property ITEM_CARD_SELECTOR : ".feed-grid__item"
property SOLD_INDICATOR_SELECTOR : "[data-testid*='sold'], .item-box__overlay--sold, .ItemBox_overlay__sold"
property HEART_BUTTON_SELECTOR : "[data-testid*='favourite'], [aria-label*='Unfavourite'], [aria-label*='Unfavorite'], .item-box__action-button--heart"

-- Toolbar offset fallback (pixels from top of Chrome window to web content)
property TOOLBAR_OFFSET_FALLBACK : 88

-- Log file path
property LOG_FILE_PATH : "~/Desktop/vinted-unfavorite-log.txt"

-- ─── Helpers ─────────────────────────────────────────────────────────────────

on randomDelay(minSec, maxSec)
	set delayTime to minSec + (random number from 0 to (maxSec - minSec))
	delay delayTime
end randomDelay

on timestampNow()
	set d to current date
	set y to year of d as text
	set m to text -2 thru -1 of ("0" & ((month of d) as integer))
	set dd to text -2 thru -1 of ("0" & (day of d))
	set h to text -2 thru -1 of ("0" & (hours of d))
	set mi to text -2 thru -1 of ("0" & (minutes of d))
	set s to text -2 thru -1 of ("0" & (seconds of d))
	return y & "-" & m & "-" & dd & " " & h & ":" & mi & ":" & s
end timestampNow

on runJS(jsCode)
	tell application "Google Chrome"
		set result to execute front window's active tab javascript jsCode
	end tell
	return result
end runJS

on appendToLog(logFile, logLine)
	try
		set logFile to POSIX file (do shell script "echo " & quoted form of logFile)
		set fp to open for access logFile with write permission
		write (logLine & linefeed) to fp starting at eof
		close access fp
	on error
		try
			close access logFile
		end try
	end try
end appendToLog

-- ─── Main Script ─────────────────────────────────────────────────────────────

-- 1. Validate Chrome is running
tell application "System Events"
	if not (exists process "Google Chrome") then
		display dialog "Google Chrome is not running. Please open Chrome and log into Vinted, then run this script again." buttons {"OK"} default button "OK" with icon stop
		return
	end if
end tell

-- Activate Chrome
tell application "Google Chrome" to activate
delay 1

-- 2. Navigate to favorites page via keyboard simulation
tell application "System Events"
	tell process "Google Chrome"
		-- Cmd+L to focus address bar
		keystroke "l" using command down
		delay 0.5
		-- Clear and type URL
		keystroke "a" using command down
		delay 0.2
		keystroke FAVORITES_URL
		delay 0.3
		key code 36 -- Enter
	end tell
end tell

-- 3. Wait for page to load (poll for content container, max 30s)
set pageLoaded to false
repeat 30 times
	try
		set checkResult to runJS("(function() {
			var cards = document.querySelectorAll('" & ITEM_CARD_SELECTOR & "');
			if (cards.length > 0) return 'loaded';
			// Also check for empty-state or no-items indicator
			if (document.querySelector('.empty-state, [data-testid=\"empty-state\"]')) return 'empty';
			return 'waiting';
		})()")
		if checkResult is "loaded" then
			set pageLoaded to true
			exit repeat
		else if checkResult is "empty" then
			display dialog "Your favorites page appears to be empty. Nothing to clean up!" buttons {"OK"} default button "OK"
			return
		end if
	end try
	delay 1
end repeat

if not pageLoaded then
	display dialog "Timed out waiting for the favorites page to load. Please make sure you're logged into Vinted and try again." buttons {"OK"} default button "OK" with icon stop
	return
end if

-- Brief extra wait for dynamic content
delay 2

-- 4. Scroll down to load all items (infinite scroll handling)
set previousCount to 0
set stableRounds to 0
repeat 50 times
	set currentCount to runJS("document.querySelectorAll('" & ITEM_CARD_SELECTOR & "').length") as integer
	if currentCount is equal to previousCount then
		set stableRounds to stableRounds + 1
		if stableRounds ≥ 3 then exit repeat
	else
		set stableRounds to 0
		set previousCount to currentCount
	end if
	-- Scroll to bottom
	tell application "System Events"
		tell process "Google Chrome"
			key code 119 -- End key
		end tell
	end tell
	delay 2
end repeat

-- Scroll back to top
tell application "System Events"
	tell process "Google Chrome"
		key code 115 -- Home key
	end tell
end tell
delay 1

-- 5. Discover sold items via read-only JS
set soldItemsJSON to runJS("(function() {
	var cards = document.querySelectorAll('" & ITEM_CARD_SELECTOR & "');
	var sold = [];
	for (var i = 0; i < cards.length; i++) {
		var card = cards[i];
		// Check multiple possible sold indicators
		var hasSoldOverlay = card.querySelector('" & SOLD_INDICATOR_SELECTOR & "');
		var hasSoldText = false;
		var overlays = card.querySelectorAll('[class*=\"overlay\"], [class*=\"badge\"], [class*=\"status\"]');
		for (var j = 0; j < overlays.length; j++) {
			var txt = overlays[j].textContent.trim().toLowerCase();
			if (['sold','vendu','verkauft','vendido','venduto','sprzedane','prodáno','predané','predano','pārdots','parduota','müüdud','eladva','продано','satılmış','продадено','vândut'].indexOf(txt) >= 0) {
				hasSoldText = true;
				break;
			}
		}
		if (hasSoldOverlay || hasSoldText) {
			var titleEl = card.querySelector('a[href*=\"/items/\"], h3, [class*=\"title\"]');
			var title = titleEl ? titleEl.textContent.trim().substring(0, 80) : 'Item ' + i;
			var linkEl = card.querySelector('a[href*=\"/items/\"]');
			var url = linkEl ? linkEl.href : '';
			sold.push({title: title, url: url, index: i});
		}
	}
	return JSON.stringify(sold);
})()")

-- Parse the JSON result
set soldItems to {}
try
	set soldItems to (do shell script "echo " & quoted form of soldItemsJSON & " | /usr/bin/python3 -c \"
import sys, json
items = json.loads(sys.stdin.read())
lines = []
for item in items:
    lines.append(item.get('title','') + '|||' + item.get('url','') + '|||' + str(item.get('index',0)))
print('\\n'.join(lines))
\"")
on error
	display dialog "Could not parse sold items from the page. The DOM structure may have changed." buttons {"OK"} default button "OK" with icon stop
	return
end try

if soldItems is "" then
	display dialog "No sold items found in your favorites. You're all clean!" buttons {"OK"} default button "OK"
	return
end if

-- Split into list of records
set AppleScript's text item delimiters to linefeed
set itemLines to text items of soldItems
set AppleScript's text item delimiters to ""

set totalItems to count of itemLines
set logEntries to {}

-- Initialize log file
set logHeader to "Vinted Unfavorite Log — Started " & timestampNow() & linefeed & "Found " & totalItems & " sold item(s) to unfavorite" & linefeed & "========================================" & linefeed
appendToLog(LOG_FILE_PATH, logHeader)

display notification "Found " & totalItems & " sold items to unfavorite" with title "Vinted Cleanup"

-- 6. Get Chrome window position for coordinate mapping
tell application "Google Chrome"
	set winBounds to bounds of front window
end tell
set winX to item 1 of winBounds
set winY to item 2 of winBounds

-- Measure toolbar height: compare window top to content area
set toolbarHeight to TOOLBAR_OFFSET_FALLBACK
try
	set contentTop to runJS("(function() {
		var el = document.elementFromPoint(window.innerWidth/2, 0);
		return window.outerHeight - window.innerHeight;
	})()") as integer
	if contentTop > 0 then set toolbarHeight to contentTop
end try

-- 7. Process each sold item
set successCount to 0
set failCount to 0
set failedItems to {}

repeat with i from 1 to totalItems
	set currentLine to item i of itemLines
	set AppleScript's text item delimiters to "|||"
	set itemParts to text items of currentLine
	set AppleScript's text item delimiters to ""

	set itemTitle to item 1 of itemParts
	set itemURL to item 2 of itemParts
	set itemIndex to (item 3 of itemParts) as integer

	-- Pre-action random delay (3–7 seconds)
	randomDelay(3, 7)

	-- Scroll the item into view and get heart button coordinates
	set coordsResult to runJS("(function() {
		var cards = document.querySelectorAll('" & ITEM_CARD_SELECTOR & "');
		var card = cards[" & itemIndex & "];
		if (!card) return 'error:card_not_found';

		// Scroll into view
		card.scrollIntoView({behavior: 'smooth', block: 'center'});

		// Wait a moment for scroll, then find heart button
		var heart = card.querySelector('" & HEART_BUTTON_SELECTOR & "');
		if (!heart) {
			// Try broader search: any button/icon that looks like a heart
			var buttons = card.querySelectorAll('button, [role=\"button\"]');
			for (var b = 0; b < buttons.length; b++) {
				var ariaLabel = (buttons[b].getAttribute('aria-label') || '').toLowerCase();
				var svg = buttons[b].querySelector('svg');
				if (ariaLabel.indexOf('fav') >= 0 || ariaLabel.indexOf('heart') >= 0 || ariaLabel.indexOf('like') >= 0 || svg) {
					heart = buttons[b];
					break;
				}
			}
		}
		if (!heart) return 'error:heart_not_found';

		var rect = heart.getBoundingClientRect();
		var x = Math.round(rect.left + rect.width / 2);
		var y = Math.round(rect.top + rect.height / 2);
		return x + ',' + y;
	})()")

	-- Allow scroll animation to complete
	delay 1

	if coordsResult starts with "error:" then
		set failCount to failCount + 1
		set end of failedItems to itemTitle & " (" & coordsResult & ")"
		set logLine to timestampNow() & " | FAIL | " & itemTitle & " | " & itemURL & " | " & coordsResult
		appendToLog(LOG_FILE_PATH, logLine)
	else
		-- Parse coordinates
		set AppleScript's text item delimiters to ","
		set coordParts to text items of coordsResult
		set AppleScript's text item delimiters to ""

		set jsX to (item 1 of coordParts) as integer
		set jsY to (item 2 of coordParts) as integer

		-- Convert to screen coordinates
		set screenX to winX + jsX
		set screenY to winY + toolbarHeight + jsY

		-- Click via System Events
		try
			tell application "System Events"
				tell process "Google Chrome"
					click at {screenX, screenY}
				end tell
			end tell

			-- Brief pause to let the UI react
			delay 1.5

			-- Verify the unfavorite action (check if heart state changed)
			set verifyResult to runJS("(function() {
				var cards = document.querySelectorAll('" & ITEM_CARD_SELECTOR & "');
				var card = cards[" & itemIndex & "];
				if (!card) return 'unknown';
				// Check if the card was removed or heart state changed
				var heart = card.querySelector('" & HEART_BUTTON_SELECTOR & "');
				if (!heart) return 'likely_success';
				var ariaLabel = (heart.getAttribute('aria-label') || '').toLowerCase();
				if (ariaLabel.indexOf('favourite') >= 0 || ariaLabel.indexOf('favorite') >= 0) return 'success';
				// Check for filled vs outline heart
				var svgPath = heart.querySelector('path');
				if (svgPath) {
					var fill = svgPath.getAttribute('fill') || '';
					if (fill === 'none' || fill === 'transparent') return 'success';
				}
				return 'unknown';
			})()")

			if verifyResult is "success" or verifyResult is "likely_success" then
				set successCount to successCount + 1
				set logLine to timestampNow() & " | OK   | " & itemTitle & " | " & itemURL
			else
				-- Count as success tentatively but note uncertainty
				set successCount to successCount + 1
				set logLine to timestampNow() & " | OK?  | " & itemTitle & " | " & itemURL & " | verification uncertain"
			end if
			appendToLog(LOG_FILE_PATH, logLine)

		on error errMsg
			set failCount to failCount + 1
			set end of failedItems to itemTitle & " (click error: " & errMsg & ")"
			set logLine to timestampNow() & " | FAIL | " & itemTitle & " | " & itemURL & " | " & errMsg
			appendToLog(LOG_FILE_PATH, logLine)
		end try
	end if

	-- Post-action random delay (1–3 seconds)
	randomDelay(1, 3)
end repeat

-- 8. Summary
set summaryText to "Unfavorited " & successCount & "/" & totalItems & " sold items."
if failCount > 0 then
	set summaryText to summaryText & linefeed & failCount & " item(s) failed:"
	repeat with f in failedItems
		set summaryText to summaryText & linefeed & "  - " & f
	end repeat
end if

-- Write summary to log
appendToLog(LOG_FILE_PATH, linefeed & "========================================")
appendToLog(LOG_FILE_PATH, "Completed: " & timestampNow())
appendToLog(LOG_FILE_PATH, summaryText)

-- Show summary dialog
display dialog summaryText & linefeed & linefeed & "Log saved to:" & linefeed & LOG_FILE_PATH buttons {"OK"} default button "OK" with title "Vinted Cleanup Complete"
