// SPDX-License-Identifier: MIT
/*
 * Preloaded into Broadcom's gpsd (gnss profile): stand-ins for the four
 * Samsung SIT RIL calls it imports from libsitril-gps.so for modem-assisted
 * GNSS (control-plane A-GPS). Without a RIL, the real GpsOpen() fails and
 * gpsd aborts (G3b). There is no modem session here, so the calls succeed
 * and do nothing; positions come from the receiver itself and from
 * internet assistance (LTO, SUPL).
 *
 * The real functions return 0 on success (GpsClose(), RegisterCallback()
 * and RequestAGPS() return 0 on their success paths), so 0 here.
 */
#define EXPORT __attribute__((visibility("default")))

EXPORT int GpsOpen(void)
{
	return 0;
}

EXPORT int GpsClose(void)
{
	return 0;
}

EXPORT int RegisterCallback(void *callback)
{
	(void)callback;
	return 0;
}

EXPORT int RequestAGPS(void *data, unsigned int len)
{
	(void)data;
	(void)len;
	return 0;
}
