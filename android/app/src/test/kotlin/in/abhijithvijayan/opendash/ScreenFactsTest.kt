package `in`.abhijithvijayan.opendash

import org.junit.Assert.assertEquals
import org.junit.Test

class ScreenFactsTest {
    @Test
    fun sizeAndBothDensities() {
        assertEquals(
            mapOf("screen_px" to "1280x768", "density" to "160", "density_default" to "236"),
            ScreenFacts.of(width = 1280, height = 768, density = 160, defaultDensity = 236),
        )
    }

    @Test
    fun portraitIsReportedAsIs() {
        assertEquals("480x800", ScreenFacts.of(width = 480, height = 800, density = 240, defaultDensity = 240)["screen_px"])
    }
}
