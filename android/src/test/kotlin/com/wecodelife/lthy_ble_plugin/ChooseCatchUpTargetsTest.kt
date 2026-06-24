package com.wecodelife.lthy_ble_plugin

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Regression tests for the [LthyBlePlugin.chooseCatchUpTargets]
 * decision function.
 *
 * These lock in the fix for the bug where a BP2/ER1/ER2 first-session
 * recording was never auto-fetched: the initial enumeration after
 * `onRecordingFinishedTransition` was mis-treated as a plain baseline
 * capture because `knownFilesByModel` was empty, and the
 * `isFirstList -> return` branch swallowed the download.
 *
 * The scenario matrix here mirrors the table in the bug report:
 *   1. Fresh connect → one measurement                    → 1 readFile
 *   2. Fresh connect → wait → one measurement             → 1 readFile (diff)
 *   3. Take two measurements in a row                     → 2 readFiles
 *   4. Plain enumeration on a fresh session               → 0 readFiles
 *   5. autoFetchOnFinish = false                          → 0 readFiles
 *   6. Pending-catch-up with empty files list             → 0 readFiles
 */
internal class ChooseCatchUpTargetsTest {

    // Shorthand alias to keep each test single-line.
    private fun chose(
        files: List<String>,
        known: Set<String> = emptySet(),
        autoFetchOnFinish: Boolean = true,
        hasPendingCatchUp: Boolean = false,
    ): List<String> = FlutterBleDevicesPlugin.chooseCatchUpTargets(
        files = files,
        known = known,
        autoFetchOnFinish = autoFetchOnFinish,
        hasPendingCatchUp = hasPendingCatchUp,
    )

    // ── #1 fresh connect → one measurement ──────────────────────────
    @Test
    fun freshConnect_oneMeasurement_returnsOne() {
        // Simulates: user connects to a freshly-powered BP2, takes one
        // measurement, SDK posts fileList = ["20260502151756"].
        // knownFilesByModel was empty when the recording-finished
        // transition set pendingCatchUp, so the tail fallback kicks in.
        val result = chose(
            files = listOf("20260502151756"),
            known = emptySet(),
            hasPendingCatchUp = true,
        )
        assertEquals(listOf("20260502151756"), result)
    }

    // ── #2 fresh connect → wait → one measurement ───────────────────
    @Test
    fun freshConnect_thenBaseline_thenOneMeasurement_returnsDiff() {
        // The baseline was captured during the wait (50 existing files),
        // then a new measurement arrives. hasPendingCatchUp is true
        // because the recording-finished transition just fired.
        val baseline = (1..50).map { "2026050214%04d".format(it) }.toSet()
        val fresh = baseline.toList() + "20260502151756"
        val result = chose(
            files = fresh,
            known = baseline,
            hasPendingCatchUp = true,
        )
        assertEquals(listOf("20260502151756"), result)
    }

    // ── #3 two measurements in a row ────────────────────────────────
    @Test
    fun twoMeasurementsInARow_secondCallReturnsNewOne() {
        // First measurement: baseline empty, tail fallback → file1.
        val first = chose(
            files = listOf("20260502151756"),
            known = emptySet(),
            hasPendingCatchUp = true,
        )
        assertEquals(listOf("20260502151756"), first)

        // Second measurement: known = {file1}, fresh list = {file1, file2}
        val second = chose(
            files = listOf("20260502151756", "20260502151830"),
            known = setOf("20260502151756"),
            hasPendingCatchUp = true,
        )
        assertEquals(listOf("20260502151830"), second)
    }

    // ── #4 plain enumeration on a fresh session ─────────────────────
    @Test
    fun plainFirstEnumeration_returnsNothing() {
        // User calls getFileList() manually on connect for inspection.
        // No recording-finished transition → hasPendingCatchUp = false.
        // Must NOT auto-pull — the 50 existing files pre-date the
        // consumer and shouldn't be mass-downloaded.
        val existing = (1..50).map { "2026050214%04d".format(it) }
        val result = chose(
            files = existing,
            known = emptySet(),
            hasPendingCatchUp = false,
        )
        assertTrue(result.isEmpty(), "plain first enumeration must be baseline only")
    }

    // ── #5 autoFetchOnFinish = false ────────────────────────────────
    @Test
    fun autoFetchDisabled_neverReturnsFiles() {
        val result = chose(
            files = listOf("20260502151756"),
            known = emptySet(),
            autoFetchOnFinish = false,
            hasPendingCatchUp = true,
        )
        assertTrue(result.isEmpty(), "autoFetchOnFinish=false must disable all auto-pulls")
    }

    // ── #6 pending catch-up but empty files list ────────────────────
    @Test
    fun pendingCatchUp_emptyFiles_returnsNothing() {
        // Pathological: recording-finished fired but the fileList came
        // back empty. Don't crash, just skip.
        val result = chose(
            files = emptyList(),
            known = emptySet(),
            hasPendingCatchUp = true,
        )
        assertTrue(result.isEmpty())
    }

    // ── Additional: blank filenames filtered out ───────────────────
    @Test
    fun blankFileNames_filteredFromDiff() {
        val result = chose(
            files = listOf("", "   ", "20260502151756"),
            known = emptySet(),
            hasPendingCatchUp = true,
        )
        // diff filters blanks, leaves one entry — no tail fallback needed.
        assertEquals(listOf("20260502151756"), result)
    }

    // ── Additional: non-recording enumeration after baseline ───────
    @Test
    fun subsequentEnumerationWithoutPendingCatchUp_returnsDiff() {
        // Consumer called getFileList() manually and a new file appeared
        // since the last baseline. Auto-pull it even without the pending
        // flag, since the baseline has already been captured.
        val result = chose(
            files = listOf("old1", "old2", "new"),
            known = setOf("old1", "old2"),
            hasPendingCatchUp = false,
        )
        assertEquals(listOf("new"), result)
    }

    // ── Additional: identical fileList → no download ───────────────
    @Test
    fun unchangedFileList_returnsNothing() {
        val result = chose(
            files = listOf("f1", "f2"),
            known = setOf("f1", "f2"),
            hasPendingCatchUp = false,
        )
        assertTrue(result.isEmpty())
    }

    // ── Additional: pendingCatchUp + unchanged list → tail fallback ─
    @Test
    fun pendingCatchUp_unchangedList_fallsBackToTail() {
        // Edge case: the SDK sometimes ACKs a save by repeating the old
        // list. Still download *something* — worst case one redundant
        // transfer, which the consumer's ledger deduplicates.
        val result = chose(
            files = listOf("f1", "f2"),
            known = setOf("f1", "f2"),
            hasPendingCatchUp = true,
        )
        assertEquals(listOf("f2"), result, "tail = newest recording when diff is empty")
    }
}
