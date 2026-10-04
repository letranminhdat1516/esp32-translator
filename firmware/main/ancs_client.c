/*
 * ANCS client: the board reads the iPhone's notifications (Apple Notification Center Service) over the iPhone's
 * own BLE link. The board stays the GATT server for the translator app; on the same link it is also the GATT
 * client of the iPhone's ANCS service. ANCS is only served over an encrypted, bonded link: ble_link.c asks for
 * encryption and calls ancs_client_on_encrypted() once a link is encrypted. Then: discover the ANCS service, its
 * three characteristics and the two CCCDs, subscribe to Data Source, then Notification Source (iOS asks once
 * whether the board may receive notifications).
 * Only one link carries ANCS. A Mac link has no ANCS service: discovery gives up on it quietly.
 * Everything here runs in the NimBLE host task (GAP events, GATT callbacks) unless noted; buffers are static
 * (the host task stack is 6 KB with ~2.7 KB headroom).
 */
#include <string.h>

#include "esp_log.h"
#include "host/ble_hs.h"

#include "ancs.h"
#include "app.h"

static const char *TAG = "ancs";

static const ble_uuid128_t s_svc_uuid = BLE_UUID128_INIT(ANCS_UUID_SVC);
static const ble_uuid128_t s_source_uuid = BLE_UUID128_INIT(ANCS_UUID_SOURCE);
static const ble_uuid128_t s_control_uuid = BLE_UUID128_INIT(ANCS_UUID_CONTROL);
static const ble_uuid128_t s_data_uuid = BLE_UUID128_INIT(ANCS_UUID_DATA);

/* ---- discovery ---- */

typedef enum { LINK_NONE = 0, LINK_DISCOVERING, LINK_READY } link_state_t;

static struct {
    uint16_t conn;                  /* the link being discovered or ready */
    link_state_t state;
    uint16_t svc_start, svc_end;
    uint16_t source_val, control_val, data_val;
    uint16_t source_end, data_end;  /* last handle of each characteristic (its descriptors end there) */
    uint16_t *open_end;             /* end of the characteristic found last, set when the next one arrives */
    uint16_t source_cccd, data_cccd;
} s_link = { .conn = BLE_HS_CONN_HANDLE_NONE };

/* An encrypted link that came up while another one was being discovered (the Mac and the iPhone together) */
static uint16_t s_waiting_conn = BLE_HS_CONN_HANDLE_NONE;
/* A link already found without ANCS (the Mac): not discovered again until it disconnects */
static uint16_t s_no_ancs_conn = BLE_HS_CONN_HANDLE_NONE;

#define DATA_SOURCE ((void *)1)   /* GATT callback arg: the Data Source step (NULL: Notification Source) */

static void notifications_ready(uint16_t conn);   /* "notifications" section below */
static void start_discovery(uint16_t conn);

static void link_reset(void)
{
    memset(&s_link, 0, sizeof(s_link));
    s_link.conn = BLE_HS_CONN_HANDLE_NONE;
}

static void next_discovery(void)
{
    uint16_t next = s_waiting_conn;
    s_waiting_conn = BLE_HS_CONN_HANDLE_NONE;
    if (next != BLE_HS_CONN_HANDLE_NONE) {
        start_discovery(next);
    }
}

static void give_up(const char *why)
{
    ESP_LOGI(TAG, "link %d: %s", s_link.conn, why);
    s_no_ancs_conn = s_link.conn;
    link_reset();
    next_discovery();
}

static int on_cccd_written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg);

static void subscribe(uint16_t cccd, void *arg)
{
    static const uint8_t notify_on[2] = { 0x01, 0x00 };
    int rc = ble_gattc_write_flat(s_link.conn, cccd, notify_on, sizeof(notify_on), on_cccd_written, arg);
    if (rc != 0) {
        ESP_LOGW(TAG, "subscription write not started: rc %d", rc);
        give_up("iPhone notifications not subscribed");
    }
}

static int on_cccd_written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg)
{
    if (conn != s_link.conn || s_link.state != LINK_DISCOVERING) {
        return 0;
    }
    bool data = arg == DATA_SOURCE;
    if (error->status != 0) {
        ESP_LOGW(TAG, "%s subscription refused: status 0x%x", data ? "Data Source" : "Notification Source",
                 error->status);
        give_up("iPhone notifications not available on this link");
        return 0;
    }
    if (data) {
        subscribe(s_link.source_cccd, NULL);
        return 0;
    }
    s_link.state = LINK_READY;
    s_waiting_conn = BLE_HS_CONN_HANDLE_NONE;   /* one ANCS link */
    notifications_ready(conn);
    return 0;
}

static int on_dsc(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle,
                  const struct ble_gatt_dsc *dsc, void *arg);

static void find_cccd(uint16_t val, uint16_t end, void *arg)
{
    if (end <= val) {
        give_up("ANCS characteristic without a CCCD");
        return;
    }
    if (ble_gattc_disc_all_dscs(s_link.conn, val, end, on_dsc, arg) != 0) {
        give_up("descriptor discovery not started");
    }
}

static int on_dsc(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle,
                  const struct ble_gatt_dsc *dsc, void *arg)
{
    if (conn != s_link.conn || s_link.state != LINK_DISCOVERING) {
        return 0;
    }
    bool data = arg == DATA_SOURCE;
    if (error->status == 0) {
        if (ble_uuid_cmp(&dsc->uuid.u, BLE_UUID16_DECLARE(BLE_GATT_DSC_CLT_CFG_UUID16)) == 0) {
            if (data) {
                s_link.data_cccd = dsc->handle;
            } else {
                s_link.source_cccd = dsc->handle;
            }
        }
        return 0;
    }
    if (error->status != BLE_HS_EDONE) {
        give_up("descriptor discovery failed");
    } else if (data) {
        find_cccd(s_link.source_val, s_link.source_end, NULL);
    } else if (s_link.data_cccd == 0 || s_link.source_cccd == 0) {
        give_up("ANCS CCCDs missing");
    } else {
        subscribe(s_link.data_cccd, DATA_SOURCE);   /* Data Source first: no attribute reply can be missed */
    }
    return 0;
}

static int on_chr(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg)
{
    if (conn != s_link.conn || s_link.state != LINK_DISCOVERING) {
        return 0;
    }
    if (error->status == 0) {
        if (s_link.open_end) {
            *s_link.open_end = chr->def_handle - 1;
            s_link.open_end = NULL;
        }
        if (ble_uuid_cmp(&chr->uuid.u, &s_source_uuid.u) == 0) {
            s_link.source_val = chr->val_handle;
            s_link.open_end = &s_link.source_end;
        } else if (ble_uuid_cmp(&chr->uuid.u, &s_control_uuid.u) == 0) {
            s_link.control_val = chr->val_handle;
        } else if (ble_uuid_cmp(&chr->uuid.u, &s_data_uuid.u) == 0) {
            s_link.data_val = chr->val_handle;
            s_link.open_end = &s_link.data_end;
        }
        return 0;
    }
    if (s_link.open_end) {
        *s_link.open_end = s_link.svc_end;
        s_link.open_end = NULL;
    }
    if (error->status != BLE_HS_EDONE || !s_link.source_val || !s_link.control_val || !s_link.data_val) {
        give_up("ANCS characteristics missing");
        return 0;
    }
    find_cccd(s_link.data_val, s_link.data_end, DATA_SOURCE);
    return 0;
}

static int on_svc(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_svc *svc, void *arg)
{
    if (conn != s_link.conn || s_link.state != LINK_DISCOVERING) {
        return 0;
    }
    if (error->status == 0) {
        s_link.svc_start = svc->start_handle;
        s_link.svc_end = svc->end_handle;
        return 0;
    }
    if (error->status != BLE_HS_EDONE || s_link.svc_start == 0) {
        give_up("no iPhone notification service (not an iPhone, or not shared)");
        return 0;
    }
    ESP_LOGI(TAG, "link %d: ANCS at 0x%04x..0x%04x", conn, s_link.svc_start, s_link.svc_end);
    if (ble_gattc_disc_all_chrs(conn, s_link.svc_start, s_link.svc_end, on_chr, NULL) != 0) {
        give_up("characteristic discovery not started");
    }
    return 0;
}

static void start_discovery(uint16_t conn)
{
    link_reset();
    s_link.conn = conn;
    s_link.state = LINK_DISCOVERING;
    if (ble_gattc_disc_svc_by_uuid(conn, &s_svc_uuid.u, on_svc, NULL) != 0) {
        give_up("service discovery not started");
    }
}

void ancs_client_on_encrypted(uint16_t conn)
{
    if (conn == s_link.conn || conn == s_no_ancs_conn) {
        return;   /* re-encryption of a link already handled */
    }
    if (s_link.state == LINK_READY) {
        return;   /* one ANCS link */
    }
    if (s_link.state == LINK_DISCOVERING) {
        s_waiting_conn = conn;
        return;
    }
    start_discovery(conn);
}

/* Disconnect bookkeeping. True when conn carried the ready ANCS link. */
static bool link_forget(uint16_t conn)
{
    if (conn == s_waiting_conn) {
        s_waiting_conn = BLE_HS_CONN_HANDLE_NONE;
    }
    if (conn == s_no_ancs_conn) {
        s_no_ancs_conn = BLE_HS_CONN_HANDLE_NONE;
    }
    if (conn != s_link.conn) {
        return false;
    }
    bool ready = s_link.state == LINK_READY;
    link_reset();
    next_discovery();
    return ready;
}

/* ---- notifications ---- */
/* Task 1 discovery probe: logs every notification's app id, and the details of notifications whose app id
 * contains "claude" or "anthropic". Replaced by the notice flow (ancs.c) in Task 4. */

#define PROBE_QUEUE 8
static uint32_t s_probe_queue[PROBE_QUEUE];
static uint8_t s_probe_flags[PROBE_QUEUE];
static int s_probe_n;
static int s_probe_step;   /* 0 idle, 1 app id asked, 2 details asked */
static uint32_t s_probe_uid;
static uint8_t s_probe_uid_flags;
static ancs_reply_t s_probe_reply;
static char s_probe_text[ANCS_MESSAGE_MAX + 1];

static void probe_next(void);

static int on_probe_written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg)
{
    if (error->status != 0) {
        ESP_LOGW(TAG, "probe: request for %lu refused, status 0x%x", (unsigned long)s_probe_uid, error->status);
        s_probe_step = 0;
        probe_next();
    }
    return 0;
}

static void probe_ask(uint32_t uid, int step)
{
    uint8_t cmd[ANCS_CMD_MAX];
    const uint8_t *ids = step == 1 ? ANCS_APP_ATTRS : ANCS_DETAIL_ATTRS;
    size_t n = step == 1 ? sizeof ANCS_APP_ATTRS : sizeof ANCS_DETAIL_ATTRS;
    size_t len = ancs_encode_get_attrs(uid, ids, n, cmd, sizeof cmd);
    ancs_reply_start(&s_probe_reply, uid, (uint8_t)n);
    s_probe_uid = uid;
    s_probe_step = step;
    int rc = ble_gattc_write_flat(s_link.conn, s_link.control_val, cmd, len, on_probe_written, NULL);
    if (rc != 0) {
        ESP_LOGW(TAG, "probe: write not started, rc %d", rc);
        s_probe_step = 0;
    }
}

static void probe_next(void)
{
    if (s_probe_step != 0 || s_probe_n == 0) {
        return;
    }
    uint32_t uid = s_probe_queue[0];
    s_probe_uid_flags = s_probe_flags[0];
    s_probe_n--;
    memmove(s_probe_queue, s_probe_queue + 1, s_probe_n * sizeof s_probe_queue[0]);
    memmove(s_probe_flags, s_probe_flags + 1, s_probe_n);
    probe_ask(uid, 1);
}

static bool contains_ci(const char *s, const char *word)   /* word in lower case */
{
    size_t n = strlen(word);
    for (; *s; s++) {
        size_t i = 0;
        while (i < n && s[i] && (s[i] | 0x20) == word[i]) {
            i++;
        }
        if (i == n) {
            return true;
        }
    }
    return false;
}

static void probe_log_attr(const char *name, uint8_t id)
{
    const uint8_t *v;
    uint16_t len;
    if (!ancs_reply_attr(&s_probe_reply, id, &v, &len)) {
        ESP_LOGI(TAG, "  %s: (missing)", name);
        return;
    }
    ancs_clean_text(v, len, s_probe_text, sizeof s_probe_text);
    ESP_LOGI(TAG, "  %s (%u bytes): \"%s\"", name, len, s_probe_text);
}

static void probe_on_source(const ancs_source_t *ev)
{
    ESP_LOGI(TAG, "source: event %u flags 0x%02x category %u count %u uid %lu", ev->event, ev->flags, ev->category,
             ev->count, (unsigned long)ev->uid);
    if (ev->event == ANCS_EVENT_REMOVED || (ev->flags & ANCS_FLAG_PRE_EXISTING) || s_probe_n == PROBE_QUEUE) {
        return;
    }
    s_probe_queue[s_probe_n] = ev->uid;
    s_probe_flags[s_probe_n++] = ev->flags;
    probe_next();
}

static void probe_on_data(const uint8_t *data, uint16_t len)
{
    if (s_probe_step == 0) {
        ESP_LOGW(TAG, "probe: %u stray Data Source bytes", len);
        return;
    }
    ancs_reply_status_t st = ancs_reply_feed(&s_probe_reply, data, len);
    if (st == ANCS_REPLY_MORE) {
        return;
    }
    int step = s_probe_step;
    s_probe_step = 0;
    if (st == ANCS_REPLY_BAD) {
        ESP_LOGW(TAG, "probe: bad reply for %lu", (unsigned long)s_probe_uid);
    } else if (step == 1) {
        const uint8_t *v;
        uint16_t n;
        s_probe_text[0] = '\0';
        if (ancs_reply_attr(&s_probe_reply, ANCS_ATTR_APP_ID, &v, &n)) {
            ancs_clean_text(v, n, s_probe_text, sizeof s_probe_text);
        }
        ESP_LOGI(TAG, "uid %lu app \"%s\"", (unsigned long)s_probe_uid, s_probe_text);
        if (contains_ci(s_probe_text, "claude") || contains_ci(s_probe_text, "anthropic")) {
            probe_ask(s_probe_uid, 2);
            return;
        }
    } else {
        ESP_LOGI(TAG, "uid %lu details (flags 0x%02x, positive action %s, negative action %s):",
                 (unsigned long)s_probe_uid, s_probe_uid_flags, (s_probe_uid_flags & ANCS_FLAG_POSITIVE) ? "yes" : "no",
                 (s_probe_uid_flags & ANCS_FLAG_NEGATIVE) ? "yes" : "no");
        probe_log_attr("title", ANCS_ATTR_TITLE);
        probe_log_attr("subtitle", ANCS_ATTR_SUBTITLE);
        probe_log_attr("message", ANCS_ATTR_MESSAGE);
        probe_log_attr("positive label", ANCS_ATTR_POSITIVE);
        probe_log_attr("negative label", ANCS_ATTR_NEGATIVE);
    }
    ancs_reply_clear(&s_probe_reply);
    probe_next();
}

static void notifications_ready(uint16_t conn)
{
    s_probe_n = 0;
    s_probe_step = 0;
    ESP_LOGI(TAG, "link %d: iPhone notifications on (discovery probe)", conn);
}

bool ancs_client_on_notify(uint16_t conn, uint16_t attr, const uint8_t *data, uint16_t len)
{
    if (conn != s_link.conn || s_link.state != LINK_READY) {
        return false;
    }
    if (attr == s_link.source_val) {
        ancs_source_t ev;
        if (ancs_parse_source(data, len, &ev)) {
            probe_on_source(&ev);
        } else {
            ESP_LOGW(TAG, "probe: Notification Source of %u bytes", len);
        }
        return true;
    }
    if (attr == s_link.data_val) {
        probe_on_data(data, len);
        return true;
    }
    return false;
}

void ancs_client_on_disconnect(uint16_t conn)
{
    if (link_forget(conn)) {
        s_probe_n = 0;
        s_probe_step = 0;
        ancs_reply_clear(&s_probe_reply);
        ESP_LOGI(TAG, "iPhone notifications off");
    }
}
