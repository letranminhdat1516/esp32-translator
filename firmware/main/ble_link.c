/*
 * BLE GATT server for the iPhone translator app.
 *
 * Service  A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A
 *   audio   ...0002  notify  : [seq u16][predictor i16][index u8][ADPCM...] (16 kHz mono)
 *   text    ...0003  write   : [flags u8][kind u8][UTF-8...]  flags bit0 = first chunk, bit1 = last chunk
 *                              kind 0 = subtitle (large), kind 1 = status line,
 *                              kind 2 = time "<unix seconds> <UTC offset minutes>" (ASCII, sent on connect),
 *                              kind 3 = language label, <= 32 bytes UTF-8, shown alone on the status line while translating ("" clears)
 *   control ...0004  r/w/notify : 1 byte: 0 = board mic off, 1 = on; the app also writes 0xFF every 20 s as a
 *                              keepalive (phone_idle.h): 60 s without any app write and the board stops streaming
 *
 *   info    ...0005  read    : open (the app reads it before pairing)
 *
 * Pairing by code (pairing.h): LE Secure Connections numeric comparison only (sm_sc_only; passkey entry and OOB
 * drop the link). Text, control and the audio / control CCCDs need an encrypted, authenticated link with a 16-byte
 * key from an SC bond, so iOS shows its pairing dialog with 6 digits on the first access and the board shows the same
 * 6 digits (pair_ui.c) with Sai / Đúng. A request is refused without drawing anything when it comes too often
 * (per peer address and overall), while another link's code is up, or while the board is locked (a short "unlock to
 * pair" notice on the lock screen instead). Locking the board while a code is up rejects it. Bonds are kept in NVS;
 * a stale bond is dropped on a MIC failure. A Just Works or legacy bond from older firmware does not count: the
 * board asks for pairing once on that link so the comparison runs, and streams nothing until it did.
 */
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "store/config/ble_store_config.h"

/* Not declared in the IDF header; defined in the NimBLE config store (NVS-backed bonds) */
void ble_store_config_init(void);

#include "app.h"
#include "font_store.h"
#include "glyphs.h"
#include "clock.h"
#include "phone_idle.h"
#include "pairing.h"

static const char *TAG = "ble";

#define SVC_UUID(last) BLE_UUID128_INIT(0x0a, 0x9b, 0x8c, 0x7d, 0x6e, 0x5f, 0x8a, 0x9d, \
                                        0x1e, 0x4c, 0x2f, 0x3b, (last), 0x00, 0xc0, 0xa7)

static const ble_uuid128_t s_svc_uuid = SVC_UUID(0x01);
static const ble_uuid128_t s_audio_uuid = SVC_UUID(0x02);
static const ble_uuid128_t s_text_uuid = SVC_UUID(0x03);
static const ble_uuid128_t s_ctrl_uuid = SVC_UUID(0x04);
static const ble_uuid128_t s_info_uuid = SVC_UUID(0x05);   /* read: [BOARD_INFO_VERSION][font_sets u32 LE] */

#define TEXT_FLAG_FIRST 0x01
#define TEXT_FLAG_LAST  0x02
#define TEXT_KIND_MAIN   0
#define TEXT_KIND_STATUS 1
#define TEXT_KIND_TIME   2
#define TEXT_KIND_LABEL  3
#define TEXT_MAX         1024

static uint16_t s_audio_handle;
static uint16_t s_text_handle;
static uint16_t s_ctrl_handle;
static uint16_t s_info_handle;

/* The iPhone link that holds the translator audio role */
static volatile uint16_t s_phone_conn = BLE_HS_CONN_HANDLE_NONE;
/* A bonded iPhone whose audio CCCD NimBLE restored from the bond when the link encrypted (a bond made by older
 * firmware, or by a phone that paired on its own): the translator app may or may not be open. NimBLE only reports
 * a CCCD write that changes the stored flags (ble_gatts.c ble_gatts_subscribe_event), and the restore has already
 * set them: when the app then writes its own CCCD (setNotifyValue(true), every connect) nothing is reported. So the link waits here and
 * becomes the iPhone audio link on the app's first write to the text or control characteristic (ESPLink writes
 * the time and the mic state on every connect). */
static volatile uint16_t s_audio_pending_conn = BLE_HS_CONN_HANDLE_NONE;
/* Last app write (text, control or keepalive) on s_phone_conn, and the host-task timer that checks it: an iPhone
 * that keeps the link after the app was swiped away must not keep the board streaming audio */
static int64_t s_phone_last_write_us;
static struct ble_npl_callout s_phone_idle_timer;
static int s_connections;
static uint8_t s_own_addr_type;
/* A pace change refused because another parameter update was still running: sent again once that update
 * completes (BLE_GAP_EVENT_CONN_UPDATE) */
static uint16_t s_pace_retry_conn = BLE_HS_CONN_HANDLE_NONE;

/* Pairing request on screen and the rate limits (host task only), its 30 s timer, the owner's answer posted from the
 * LVGL task (bound to the request it was given for), and the cancel posted by the shell when the board locks */
static pair_t s_pair;
static struct ble_npl_callout s_pair_timer;
static struct ble_npl_event s_pair_answer_ev;
static struct ble_npl_event s_pair_cancel_ev;
static portMUX_TYPE s_pair_answer_mux = portMUX_INITIALIZER_UNLOCKED;
static uint16_t s_pair_answer_conn = BLE_HS_CONN_HANDLE_NONE;
static uint32_t s_pair_answer_id = PAIR_ID_NONE;
static bool s_pair_answer_yes;
/* Links on which the board already asked to upgrade an unauthenticated key (once per link) */
static uint16_t s_upgrade_asked[CONFIG_BT_NIMBLE_MAX_CONNECTIONS] = { [0 ... CONFIG_BT_NIMBLE_MAX_CONNECTIONS - 1] = BLE_HS_CONN_HANDLE_NONE };

static char s_text_buf[TEXT_MAX + 1];
static size_t s_text_len;

static void start_advertising(void);

/* A connection interval that fits real-time audio: 30-45 ms (two 20 ms packets per event) */
static void set_fast_pace(uint16_t conn)
{
    struct ble_gap_upd_params p = { .itvl_min = 24, .itvl_max = 36, .latency = 0, .supervision_timeout = 400 };
    int rc = ble_gap_update_params(conn, &p);
    ESP_LOGI(TAG, "link %d: fast pace (rc %d)", conn, rc);
    if (rc == BLE_HS_EALREADY) {
        s_pace_retry_conn = conn;
    } else if (conn == s_pace_retry_conn) {
        s_pace_retry_conn = BLE_HS_CONN_HANDLE_NONE;   /* this request supersedes the waiting one */
    }
}

/* The link's security for pairing.h: NimBLE's sec_state, plus whether the stored bond for this peer was made with
 * LE Secure Connections (NimBLE keeps that flag only in the bond). False: no such link. */
static bool link_sec(uint16_t conn, pair_sec_t *out)
{
    struct ble_gap_conn_desc desc;
    if (ble_gap_conn_find(conn, &desc) != 0) {
        return false;
    }
    *out = (pair_sec_t){
        .encrypted = desc.sec_state.encrypted,
        .authenticated = desc.sec_state.authenticated,
        .key_size = desc.sec_state.key_size,
        .sc_bond = false,
    };
    if (desc.sec_state.encrypted && desc.sec_state.bonded) {
        struct ble_store_key_sec key = { .peer_addr = desc.peer_id_addr };
        struct ble_store_value_sec bond;
        if (ble_store_read_peer_sec(&key, &bond) == 0) {
            out->sc_bond = bond.ltk_present && bond.sc && bond.authenticated;
        }
    }
    return true;
}

/* May this link use chr? (pairing.h: protected ones need the Secure Connections numeric-comparison bond) */
static bool link_allows(uint16_t conn, pair_chr_t chr)
{
    pair_sec_t sec;
    if (!link_sec(conn, &sec)) {
        return false;
    }
    return pair_chr_allowed(chr, &sec);
}

/* conn waits for the translator app (restored audio CCCD, or the app went silent) */
static void set_audio_pending(uint16_t conn)
{
    s_audio_pending_conn = conn;
}

/* The translator app subscribed to audio on conn: it becomes the iPhone audio link */
static void phone_audio_on(uint16_t conn)
{
    if (conn == s_audio_pending_conn) {
        s_audio_pending_conn = BLE_HS_CONN_HANDLE_NONE;
    }
    if (s_phone_conn == conn) {
        return;
    }
    if (!link_allows(conn, PAIR_CHR_AUDIO)) {
        /* A CCCD restored from a Just Works bond (old firmware): no audio until the link is paired by code. Wait
         * for the app's first authenticated write instead (translator_write_from) */
        ESP_LOGW(TAG, "link %d: not paired by code, no audio until it is", conn);
        set_audio_pending(conn);
        return;
    }
    if (s_phone_conn != BLE_HS_CONN_HANDLE_NONE) {
        ESP_LOGW(TAG, "audio role already held, ignoring second subscriber");
        return;
    }
    s_phone_conn = conn;
    s_phone_last_write_us = esp_timer_get_time();
    ble_npl_callout_reset(&s_phone_idle_timer, ble_npl_time_ms_to_ticks32(PHONE_IDLE_TIMEOUT_MS));
    ESP_LOGI(TAG, "iPhone audio on");
    ESP_LOGI(TAG, "internal DMA free %u, largest block %u", (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
    /* Audio needs the fast pace: ask again when the link runs slower than 45 ms (the phone chose a slower one, or a
     * retry NimBLE dropped: an update that times out is freed without an event) */
    struct ble_gap_conn_desc desc;
    if (ble_gap_conn_find(conn, &desc) == 0 && desc.conn_itvl > 36) {
        set_fast_pace(conn);
    }
    app_on_connection_changed(true);
}

/* The iPhone audio role ends (unsubscribe, disconnect, silent app): stop streaming */
static void phone_audio_off(void)
{
    s_phone_conn = BLE_HS_CONN_HANDLE_NONE;
    ble_npl_callout_stop(&s_phone_idle_timer);
    app_on_connection_changed(false);
}

/* Host task (NimBLE callout): the app has not written for PHONE_IDLE_TIMEOUT_US? Then it is gone (swiped away,
 * crashed) while iOS keeps the link: leave the role like an audio unsubscribe, keep the link, and wait for
 * the app on it again (a later write promotes it, as on a restored link) */
static void on_phone_idle_check(struct ble_npl_event *ev)
{
    (void)ev;
    uint16_t conn = s_phone_conn;
    if (conn == BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    uint32_t ms = phone_idle_check_ms(s_phone_last_write_us, esp_timer_get_time());
    if (ms != 0) {
        ble_npl_callout_reset(&s_phone_idle_timer, ble_npl_time_ms_to_ticks32(ms));
        return;
    }
    ESP_LOGI(TAG, "iPhone app silent for %d s — audio off", (int)(PHONE_IDLE_TIMEOUT_US / 1000000));
    set_audio_pending(conn);   /* a mic tap or the app's next write takes the role back */
    phone_audio_off();
}

/* Board mic tapped while the iPhone link waits (app silent or not seen yet): host task, posted by
 * ble_link_wake_phone(). Take the role back and turn the mic on: the control notification wakes a suspended app,
 * whose writes keep the role; a dead app loses it again after PHONE_IDLE_TIMEOUT_US. */
static struct ble_npl_event s_wake_ev;
static volatile rec_lang_t s_wake_lang;

static void on_wake_phone(struct ble_npl_event *ev)
{
    (void)ev;
    uint16_t conn = s_audio_pending_conn;
    if (s_phone_conn != BLE_HS_CONN_HANDLE_NONE || conn == BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    if (!link_allows(conn, PAIR_CHR_AUDIO)) {
        ESP_LOGW(TAG, "board mic tapped: the waiting link %d is not paired by code", conn);
        return;
    }
    ESP_LOGI(TAG, "board mic tapped: iPhone audio back on the waiting link %d", conn);
    phone_audio_on(conn);
    if (s_phone_conn == conn) {
        app_request_recording(s_wake_lang);   /* main.c turns the mic on and notifies the control value */
    }
}

bool ble_link_wake_phone(rec_lang_t lang)
{
    if (s_audio_pending_conn == BLE_HS_CONN_HANDLE_NONE) {
        return false;
    }
    s_wake_lang = lang;
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_wake_ev);
    return true;
}

/* A write to the translator characteristics: the app is alive. On a link whose audio CCCD was only restored (or
 * whose app went silent), the app is back. */
static void translator_write_from(uint16_t conn)
{
    if (conn == s_phone_conn) {
        s_phone_last_write_us = esp_timer_get_time();
        return;
    }
    if (conn == s_audio_pending_conn) {
        ESP_LOGI(TAG, "translator app active on the restored link");
        phone_audio_on(conn);
        /* The board mic went off with the role: tell the app (it may still show it on after a silent spell) */
        ble_link_notify_control(app_get_recording());
    }
}

static void handle_text_write(const uint8_t *data, uint16_t len)
{
    if (len < 2) {
        return;
    }
    uint8_t flags = data[0];
    uint8_t kind = data[1];
    if (flags & TEXT_FLAG_FIRST) {
        s_text_len = 0;
    }
    size_t n = len - 2;
    if (s_text_len + n > TEXT_MAX) {
        n = TEXT_MAX - s_text_len;
    }
    memcpy(s_text_buf + s_text_len, data + 2, n);
    s_text_len += n;

    if (flags & TEXT_FLAG_LAST) {
        s_text_buf[s_text_len] = '\0';
        if (kind == TEXT_KIND_TIME) {
            clock_sync_text(s_text_buf);
        } else if (kind == TEXT_KIND_STATUS) {
            ui_show_status(s_text_buf);
        } else if (kind == TEXT_KIND_LABEL) {
            char label[LABEL_MAX + 1];
            if (label_normalize(s_text_buf, s_text_len, label)) {
                ui_set_label(label);
            } else {
                ESP_LOGW(TAG, "language label is not valid UTF-8, ignored");
            }
        } else {
            ui_show_text(s_text_buf);
        }
        s_text_len = 0;
    }
}

static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    uint8_t buf[256];
    uint16_t len = 0;

    if (attr_handle == s_info_handle && ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        uint32_t sets = BOARD_BASE_FONT_SETS | font_store_sets();
        uint8_t info[5] = { BOARD_INFO_VERSION, (uint8_t)sets, (uint8_t)(sets >> 8), (uint8_t)(sets >> 16),
                            (uint8_t)(sets >> 24) };
        return os_mbuf_append(ctxt->om, info, sizeof(info)) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    /* NimBLE enforces the ENC / AUTHEN flags before this runs; checked again so nothing slips through */
    if ((attr_handle == s_ctrl_handle && !link_allows(conn_handle, PAIR_CHR_CTRL)) ||
        (attr_handle == s_text_handle && !link_allows(conn_handle, PAIR_CHR_TEXT))) {
        return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    }
    if (attr_handle == s_ctrl_handle) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            uint8_t state = app_get_recording();
            return os_mbuf_append(ctxt->om, &state, 1) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            if (ble_hs_mbuf_to_flat(ctxt->om, buf, 1, &len) != 0 || len != 1) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            if (buf[0] == PHONE_CTRL_KEEPALIVE) {
                translator_write_from(conn_handle);   /* the app is alive; the mic state is unchanged */
                return 0;
            }
            if (buf[0] > REC_VI) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            translator_write_from(conn_handle);
            app_request_recording((rec_lang_t)buf[0]);
            return 0;
        }
    } else if (attr_handle == s_text_handle && ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len) != 0) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        translator_write_from(conn_handle);
        handle_text_write(buf, len);
        return 0;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_audio_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC |
                         BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHEN,
                .val_handle = &s_audio_handle,
            },
            {
                .uuid = &s_text_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_AUTHEN,
                .val_handle = &s_text_handle,
            },
            {
                .uuid = &s_ctrl_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC | BLE_GATT_CHR_F_READ_AUTHEN |
                         BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC | BLE_GATT_CHR_F_WRITE_AUTHEN |
                         BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC |
                         BLE_GATT_CHR_F_NOTIFY_INDICATE_AUTHEN,
                .val_handle = &s_ctrl_handle,
            },
            {
                .uuid = &s_info_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_READ,
                .val_handle = &s_info_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

/* ---- pairing by code (host task) ---- */

static void inject_numcmp(uint16_t conn, bool accept)
{
    struct ble_sm_io io = { .action = BLE_SM_IOACT_NUMCMP, .numcmp_accept = accept ? 1 : 0 };
    int rc = ble_sm_inject_io(conn, &io);
    ESP_LOGI(TAG, "link %d: pairing code %s (rc %d)", conn, accept ? "confirmed" : "rejected", rc);
}

/* The request on screen ended with outcome: answer the SM and close the view */
static void pair_finish(uint16_t conn, pair_outcome_t outcome)
{
    if (outcome == PAIR_OUT_NONE) {
        return;
    }
    ble_npl_callout_stop(&s_pair_timer);
    if (outcome == PAIR_OUT_TIMEOUT) {
        ESP_LOGW(TAG, "link %d: no answer within %d s", conn, (int)(PAIR_TIMEOUT_US / 1000000));
    }
    inject_numcmp(conn, outcome == PAIR_OUT_ACCEPT);
    pair_ui_close();
}

static void on_pair_timer(struct ble_npl_event *ev)
{
    (void)ev;
    int64_t now = esp_timer_get_time();
    pair_outcome_t out = pair_tick(&s_pair, now);
    if (out != PAIR_OUT_NONE) {
        pair_finish(s_pair.conn, out);
    } else if (s_pair.phase == PAIR_SHOWING) {
        int64_t left_ms = (s_pair.deadline_us - now + 999) / 1000;
        ble_npl_callout_reset(&s_pair_timer, ble_npl_time_ms_to_ticks32(left_ms < 10 ? 10 : (uint32_t)left_ms));
    }
}

/* Applied only if (conn, id) is still the request on screen and its code has been up for PAIR_ARM_US */
static void on_pair_answer(struct ble_npl_event *ev)
{
    (void)ev;
    taskENTER_CRITICAL(&s_pair_answer_mux);
    uint16_t conn = s_pair_answer_conn;
    uint32_t id = s_pair_answer_id;
    bool yes = s_pair_answer_yes;
    s_pair_answer_id = PAIR_ID_NONE;
    taskEXIT_CRITICAL(&s_pair_answer_mux);
    if (id == PAIR_ID_NONE) {
        return;
    }
    pair_outcome_t out = pair_answer(&s_pair, conn, id, yes, esp_timer_get_time());
    if (out == PAIR_OUT_NONE) {
        ESP_LOGW(TAG, "link %d: answer for request %lu dropped (not the code on screen, or too early)", conn,
                 (unsigned long)id);
        return;
    }
    pair_finish(conn, out);
}

void ble_link_pair_answer(uint16_t conn, uint32_t id, bool yes)
{
    taskENTER_CRITICAL(&s_pair_answer_mux);
    s_pair_answer_conn = conn;
    s_pair_answer_id = id;
    s_pair_answer_yes = yes;
    taskEXIT_CRITICAL(&s_pair_answer_mux);
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_pair_answer_ev);
}

/* The board locked: a code must not stay up for approval on a locked board */
static void on_pair_cancel(struct ble_npl_event *ev)
{
    (void)ev;
    uint16_t conn = s_pair.conn;
    pair_outcome_t out = pair_cancel(&s_pair);
    if (out != PAIR_OUT_NONE) {
        ESP_LOGW(TAG, "link %d: board locked while its code was up", conn);
        pair_finish(conn, out);
    }
}

void ble_link_pair_cancel(void)
{
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_pair_cancel_ev);
}

static void on_passkey_action(uint16_t conn, const struct ble_gap_passkey_params *params)
{
    struct ble_gap_conn_desc desc;
    if (ble_gap_conn_find(conn, &desc) != 0) {
        return;
    }
    uint8_t addr[PAIR_ADDR_LEN];
    addr[0] = desc.peer_id_addr.type;
    memcpy(addr + 1, desc.peer_id_addr.val, 6);
    modes_t m;
    shell_snapshot(&m);
    bool numcmp = params->action == BLE_SM_IOACT_NUMCMP;
    uint32_t passkey = numcmp ? params->numcmp : 0;

    switch (pair_begin(&s_pair, conn, addr, numcmp, m.locked, passkey, esp_timer_get_time())) {
    case PAIR_BEGIN_SHOW:
        ESP_LOGI(TAG, "link %d: pairing, compare code %06lu (request %lu)", conn, (unsigned long)s_pair.passkey,
                 (unsigned long)s_pair.id);
        ble_npl_callout_reset(&s_pair_timer, ble_npl_time_ms_to_ticks32(PAIR_TIMEOUT_MS));
        pair_ui_show(conn, s_pair.id, s_pair.passkey);
        break;
    case PAIR_BEGIN_REJECT_METHOD:
        /* Passkey entry / OOB (only possible with a peer that cannot do numeric comparison): not offered here */
        ESP_LOGW(TAG, "link %d: pairing action %d is not numeric comparison, dropping the link", conn, params->action);
        ble_gap_terminate(conn, BLE_ERR_AUTH_FAIL);
        break;
    case PAIR_BEGIN_REJECT_RATE:
        ESP_LOGW(TAG, "link %d: pairing requests too often from this peer (or overall), rejected", conn);
        inject_numcmp(conn, false);
        break;
    case PAIR_BEGIN_REJECT_LOCKED:
        ESP_LOGW(TAG, "link %d: pairing while the board is locked, rejected", conn);
        inject_numcmp(conn, false);
        lock_ui_notice("Mở khoá board để ghép", PAIR_NOTICE_MS);
        break;
    case PAIR_BEGIN_REJECT_BUSY:
        ESP_LOGW(TAG, "link %d: pairing while link %d's code is up, rejected", conn, s_pair.conn);
        inject_numcmp(conn, false);
        break;
    }
}

/* Upgrade bookkeeping: true if conn was already asked once */
static bool upgrade_asked(uint16_t conn, bool mark)
{
    for (int i = 0; i < CONFIG_BT_NIMBLE_MAX_CONNECTIONS; i++) {
        if (s_upgrade_asked[i] == conn) {
            return true;
        }
    }
    if (mark) {
        for (int i = 0; i < CONFIG_BT_NIMBLE_MAX_CONNECTIONS; i++) {
            if (s_upgrade_asked[i] == BLE_HS_CONN_HANDLE_NONE) {
                s_upgrade_asked[i] = conn;
                break;
            }
        }
    }
    return false;
}

static void upgrade_forget(uint16_t conn)
{
    for (int i = 0; i < CONFIG_BT_NIMBLE_MAX_CONNECTIONS; i++) {
        if (s_upgrade_asked[i] == conn) {
            s_upgrade_asked[i] = BLE_HS_CONN_HANDLE_NONE;
        }
    }
}

static void on_enc_change(uint16_t conn, int status)
{
    pair_sec_t sec = { 0 };
    bool found = link_sec(conn, &sec);
    if (status != 0) {
        sec.encrypted = false;
    }
    ESP_LOGI(TAG, "link %d: encryption %s (status %d), key %u bytes%s%s%s", conn, sec.encrypted ? "on" : "failed",
             status, sec.key_size, sec.authenticated ? ", authenticated" : "", sec.sc_bond ? ", SC bond" : "",
             found && pair_link_secure(&sec) ? ": paired by code" : "");
    if (pair_end(&s_pair, conn)) {   /* pairing finished either way while its code was up */
        ble_npl_callout_stop(&s_pair_timer);
        pair_ui_close();
    }
    if (found && pair_should_upgrade(&sec, upgrade_asked(conn, false))) {
        upgrade_asked(conn, true);
        int rc = ble_gap_security_initiate(conn);
        ESP_LOGW(TAG, "link %d: bond without a Secure Connections code (older firmware): asking to pair by code (rc %d)",
                 conn, rc);
    }
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            start_advertising();
            break;
        }
        s_connections++;
        ESP_LOGI(TAG, "connected (%d link%s)", s_connections, s_connections > 1 ? "s" : "");
        /* 2M PHY + a connection interval that fits real-time audio (30 ms: two 20 ms packets per event) */
        ble_gap_set_prefered_le_phy(event->connect.conn_handle, BLE_GAP_LE_PHY_2M_MASK,
                                    BLE_GAP_LE_PHY_2M_MASK, BLE_GAP_LE_PHY_CODED_ANY);
        set_fast_pace(event->connect.conn_handle);
        if (s_connections < CONFIG_BT_NIMBLE_MAX_CONNECTIONS) {
            start_advertising();   /* keep a slot open: the iPhone can come back while its old link lingers */
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        if (s_connections > 0) {
            s_connections--;
        }
        ESP_LOGI(TAG, "disconnected, reason 0x%x", event->disconnect.reason);
        if (event->disconnect.reason == BLE_HS_HCI_ERR(BLE_ERR_CONN_TERM_MIC)) {
            /* MIC failure: our stored keys for this peer no longer match (it forgot the bond, e.g. "Forget This
             * Device" on the iPhone). Drop them so the next connection pairs from scratch instead of
             * failing the same way every time */
            ESP_LOGW(TAG, "link %d: stale bond (MIC failure), deleting it", event->disconnect.conn.conn_handle);
            ble_store_util_delete_peer(&event->disconnect.conn.peer_id_addr);
        }
        upgrade_forget(event->disconnect.conn.conn_handle);
        if (pair_end(&s_pair, event->disconnect.conn.conn_handle)) {
            ble_npl_callout_stop(&s_pair_timer);
            pair_ui_close();
        }
        if (event->disconnect.conn.conn_handle == s_phone_conn) {
            phone_audio_off();
        }
        if (event->disconnect.conn.conn_handle == s_pace_retry_conn) {
            s_pace_retry_conn = BLE_HS_CONN_HANDLE_NONE;
        }
        if (event->disconnect.conn.conn_handle == s_audio_pending_conn) {
            s_audio_pending_conn = BLE_HS_CONN_HANDLE_NONE;
        }
        start_advertising();
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_audio_handle) {
            uint16_t conn = event->subscribe.conn_handle;
            bool on = event->subscribe.cur_notify;
            if (on && event->subscribe.reason == BLE_GAP_SUBSCRIBE_REASON_RESTORE) {
                /* The iPhone is bonded: NimBLE restored its old audio CCCD as the link encrypted, also when iOS
                 * connects without the translator app. Do not stream yet: s_audio_pending_conn. */
                if (conn != s_phone_conn) {
                    set_audio_pending(conn);
                    ESP_LOGI(TAG, "iPhone audio subscription restored from the bond: waiting for the app");
                }
            } else if (on) {
                phone_audio_on(conn);
            } else {
                if (conn == s_audio_pending_conn) {
                    s_audio_pending_conn = BLE_HS_CONN_HANDLE_NONE;
                }
                if (conn == s_phone_conn) {
                    ESP_LOGI(TAG, "iPhone audio off");
                    phone_audio_off();
                }
            }
        }
        break;

    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        /* Peer lost its key (or re-installed): drop the old bond and let it pair again */
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
            ble_store_util_delete_peer(&desc.peer_id_addr);
        }
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }

    case BLE_GAP_EVENT_CONN_UPDATE: {
        uint16_t conn = event->conn_update.conn_handle;
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(conn, &desc) == 0) {
            ESP_LOGI(TAG, "link %d: parameters updated (status %d): interval %u (x1.25 ms), latency %u, timeout %u0 ms",
                     conn, event->conn_update.status, desc.conn_itvl, desc.conn_latency, desc.supervision_timeout);
        }
        if (conn == s_pace_retry_conn) {
            s_pace_retry_conn = BLE_HS_CONN_HANDLE_NONE;
            set_fast_pace(conn);   /* still busy: it waits for the next completed update again */
        }
        break;
    }

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU %d", event->mtu.value);
        break;

    case BLE_GAP_EVENT_ENC_CHANGE:
        on_enc_change(event->enc_change.conn_handle, event->enc_change.status);
        break;

    case BLE_GAP_EVENT_PASSKEY_ACTION:
        on_passkey_action(event->passkey.conn_handle, &event->passkey.params);
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        start_advertising();
        break;

    default:
        break;
    }
    return 0;
}

/* Advertising interval in 0.625 ms units. Fast (stack default) while nobody is connected; once one link is
 * up (e.g. the iPhone streaming audio) only the second slot is offered, slowly, to save radio time. */
#define ADV_SLOW_ITVL_MIN 1280   /* 800 ms */
#define ADV_SLOW_ITVL_MAX 1600   /* 1000 ms */

static void start_advertising(void)
{
    if (s_connections >= CONFIG_BT_NIMBLE_MAX_CONNECTIONS) {
        return;
    }
    /* Restart so the interval always matches the current link count */
    if (ble_gap_adv_active()) {
        ble_gap_adv_stop();
    }

    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = &s_svc_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv fields rc=%d", rc);
        return;
    }

    /* Scan response: the name, shortened to fit 31 bytes (2 + 29). The full name stays the GAP device name. */
    const char *name = ble_svc_gap_device_name();
    size_t name_len = strlen(name);
    struct ble_hs_adv_fields rsp = { 0 };
    rsp.name = (const uint8_t *)name;
    rsp.name_len = name_len > 29 ? 29 : name_len;
    rsp.name_is_complete = name_len <= 29;
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) {
        ESP_LOGE(TAG, "scan response rc=%d", rc);
    }

    struct ble_gap_adv_params adv = { 0 };
    adv.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv.disc_mode = BLE_GAP_DISC_MODE_GEN;
    if (s_connections > 0) {
        adv.itvl_min = ADV_SLOW_ITVL_MIN;
        adv.itvl_max = ADV_SLOW_ITVL_MAX;
    }
    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "adv start rc=%d", rc);
    }
}

static void hash_bytes(uint32_t *h, const void *data, size_t len)
{
    const uint8_t *p = data;
    for (size_t i = 0; i < len; i++) {
        *h = (*h ^ p[i]) * 16777619u;   /* FNV-1a */
    }
}

/* Bonded peers cache this GATT table. When a firmware update changes it (e.g. the companion service of older
 * firmware was removed), mark Service Changed once: NimBLE indicates it to each bonded peer when it reconnects, and
 * the peer rediscovers instead of keeping the old table. The range starts at the translator service.
 * Known limits: the hash is stored right away, before any peer got the indication (NimBLE persists the pending
 * indication per bonded peer, but a peer that bonds later never needs it); a change to the translator service or
 * the GAP / GATT services would need its own range (they are not hashed here). */
static void announce_gatt_changes(void)
{
    uint32_t hash = 2166136261u;
    hash_bytes(&hash, "svcchg:translator", 17);   /* the announced range changed: re-announce once */
    for (const struct ble_gatt_svc_def *svc = s_services; svc->type != 0; svc++) {
        hash_bytes(&hash, svc->uuid, sizeof(ble_uuid128_t));
        for (const struct ble_gatt_chr_def *chr = svc->characteristics; chr->uuid != NULL; chr++) {
            hash_bytes(&hash, chr->uuid, sizeof(ble_uuid128_t));
            hash_bytes(&hash, &chr->flags, sizeof(chr->flags));
        }
    }
    nvs_handle_t nvs;
    if (nvs_open("ble_link", NVS_READWRITE, &nvs) != ESP_OK) {
        return;
    }
    uint32_t stored = 0;
    if (nvs_get_u32(nvs, "gatt_hash", &stored) != ESP_OK || stored != hash) {
        uint16_t start;
        if (ble_gatts_find_svc(&s_svc_uuid.u, &start) == 0) {
            ESP_LOGI(TAG, "GATT table changed (%08lx -> %08lx): Service Changed 0x%04x..0xffff for bonded peers",
                     (unsigned long)stored, (unsigned long)hash, start);
            ble_svc_gatt_changed(start, 0xffff);
            nvs_set_u32(nvs, "gatt_hash", hash);
            nvs_commit(nvs);
        } else {
            ESP_LOGW(TAG, "GATT table changed but the translator service was not found: no Service Changed sent");
        }
    }
    nvs_close(nvs);
}

static void on_sync(void)
{
    announce_gatt_changes();
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    start_advertising();
    ESP_LOGI(TAG, "advertising as \"%s\"", ble_svc_gap_device_name());
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "host reset, reason %d", reason);
}

static void host_task(void *param)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void ble_link_init(void)
{
    ESP_ERROR_CHECK(nimble_port_init());
    ble_npl_callout_init(&s_phone_idle_timer, nimble_port_get_dflt_eventq(), on_phone_idle_check, NULL);
    ble_npl_event_init(&s_wake_ev, on_wake_phone, NULL);
    pair_init(&s_pair);
    ble_npl_callout_init(&s_pair_timer, nimble_port_get_dflt_eventq(), on_pair_timer, NULL);
    ble_npl_event_init(&s_pair_answer_ev, on_pair_answer, NULL);
    ble_npl_event_init(&s_pair_cancel_ev, on_pair_cancel, NULL);
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    /* LE Secure Connections numeric comparison: the screen shows the code, Sai / Đúng answer it */
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_DISPLAY_YESNO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    /* Secure Connections only: legacy pairing requests and keys shorter than 16 bytes fail in the SM itself
     * (also CONFIG_BT_NIMBLE_SM_SC_ONLY=1 in sdkconfig.defaults, the default this field starts from) */
    ble_hs_cfg.sm_sc_only = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(s_services));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(s_services));

    ble_store_config_init();
    nimble_port_freertos_init(host_task);
}

bool ble_link_audio_ready(void)
{
    return s_phone_conn != BLE_HS_CONN_HANDLE_NONE;
}

uint16_t ble_link_payload_max(void)
{
    if (s_phone_conn == BLE_HS_CONN_HANDLE_NONE) {
        return 20;
    }
    return ble_att_mtu(s_phone_conn) - 3;
}

bool ble_link_send_audio(const uint8_t *data, uint16_t len)
{
    for (int attempt = 0; attempt < 5; attempt++) {
        if (!ble_link_audio_ready()) {
            return false;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(data, len);
        if (om == NULL) {
            vTaskDelay(pdMS_TO_TICKS(2));
            continue;
        }
        int rc = ble_gatts_notify_custom(s_phone_conn, s_audio_handle, om);
        if (rc == 0) {
            return true;
        }
        if (rc != BLE_HS_ENOMEM) {
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    return false;
}

void ble_link_notify_control(uint8_t state)
{
    (void)state; /* the value is read back through chr_access */
    /* The waiting link too: the notification wakes a suspended app */
    if (s_phone_conn != BLE_HS_CONN_HANDLE_NONE || s_audio_pending_conn != BLE_HS_CONN_HANDLE_NONE) {
        ble_gatts_chr_updated(s_ctrl_handle);
    }
}
