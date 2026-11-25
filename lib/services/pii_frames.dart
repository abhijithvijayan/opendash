/// CAN frame ids that carry the scooter's identifiers or a rider secret.
/// The whole-bus recorders ([BusLog], [RawRecorder]) mask the eight data
/// bytes of these frames before anything is written — to the changed-frames
/// file, the bursts and the keyframes — so a plaintext VIN, MAC, serial or
/// passcode never reaches disk. The frame id, length and timing are kept, so
/// the bus shape (which ids at what rate) stays intact; only the payload is
/// zeroed. Readers know a zeroed payload here is policy, not a real zero,
/// because the file header lists these ids under `pii_masked`.
///
/// Confirmed leaked in a real capture before this guard: the VIN on 0x689,
/// battery serials on 0x110, and the BLE MAC on 0x696 and embedded in
/// 0x691. The rest are on the list because the CAN database names them as
/// identifier or passcode frames, even though they did not broadcast
/// during that ride.
///
/// The export scrub (`scripts/raw-recording.py --scrub`) stays as a second
/// line of defence for any text-bearing frame this list does not name.
const Set<int> piiFrameIds = {
  0x689, // Vehicle_VIN_Info — the 17-char VIN, multiplexed
  0xbb1, // Ecos_Vin_Config_Info
  0x110, // Battery_IDs — pack serial strings
  0x696, // BLE_MAC_Address — the head unit's BLE MAC
  0x6bd, // MAC_Address
  0x690, // SOM_BLEto_BCM — BLE pairing, carries the MAC
  0x691, // BCM_BLEto_SOM — BLE pairing, carries the MAC
  0x694, // Hotspot_Passcode
  0x6a9, // Passcode_Cmd_From_BLE — passcode digits
  0x6aa, // ACK_Passcode_Cmd — carries User_ID
  0x6a2, // CommandFromBLE
  0x584, // EV_Identification_1 — EVSE (charger) identity
  0x585, // EV_Identification_2
};
