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
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
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
/* The notice flow (ancs.c): host task, plus ancs_client_close() from the shell / LVGL task, so it is guarded by
 * s_flow_lock. Never call phone_ui_* or chime_play (display lock, queues) with s_flow_lock held: the order is
 * always display lock -> flow lock. */
static ancs_flow_t s_flow;
static SemaphoreHandle_t s_flow_lock;
static StaticSemaphore_t s_flow_lock_buf;
static ancs_notice_t s_snapshot;   /* host task: the notice handed to phone_ui.c, cleared right after */
/* The ready link's Control Point, for actions from the LVGL task (under s_flow_lock) */
static uint16_t s_flow_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_flow_control;

void ancs_client_init(void)
{
    s_flow_lock = xSemaphoreCreateMutexStatic(&s_flow_lock_buf);
    ancs_flow_init(&s_flow);
}

static void flow_lock(void)
{
    xSemaphoreTake(s_flow_lock, portMAX_DELAY);
}

static void flow_unlock(void)
{
    xSemaphoreGive(s_flow_lock);
}

static uint32_t now_ms(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

static int on_command_written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr,
                              void *arg);

/* Writes the next Control Point command the flow wants (one outstanding at a time). A write that cannot start
 * is dropped and the next one tried. */
static void pump(void)
{
    for (int tries = 0; tries < ANCS_QUEUE_MAX; tries++) {
        uint8_t cmd[ANCS_CMD_MAX];
        flow_lock();
        size_t n = s_link.state == LINK_READY ? ancs_flow_next(&s_flow, now_ms(), cmd) : 0;
        flow_unlock();
        if (n == 0) {
            return;
        }
        if (ble_gattc_write_flat(s_link.conn, s_link.control_val, cmd, n, on_command_written, NULL) == 0) {
            return;
        }
        flow_lock();
        ancs_flow_on_error(&s_flow);
        flow_unlock();
    }
}

static int on_command_written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr,
                              void *arg)
{
    if (error->status == 0 || conn != s_link.conn) {
        return 0;
    }
    ESP_LOGW(TAG, "attribute request refused by the iPhone: status 0x%x", error->status);
    flow_lock();
    ancs_flow_on_error(&s_flow);
    flow_unlock();
    pump();
    return 0;
}

/* s_flow_lock not held: hands a result to the screen */
static void deliver(ancs_out_t out, uint32_t uid)
{
    if (out == ANCS_OUT_SHOW || out == ANCS_OUT_UPDATE) {
        modes_t m;
        shell_snapshot(&m);
        if (!modes_notice_allowed(&m)) {
            /* A Mac request has the screen: no notice, no chime over it; the iPhone keeps the notification */
            ESP_LOGI(TAG, "notice %lu not shown: a Mac request is up", (unsigned long)s_snapshot.uid);
            flow_lock();
            ancs_flow_close(&s_flow, s_snapshot.uid);
            flow_unlock();
            memset(&s_snapshot, 0, sizeof(s_snapshot));
            return;
        }
        phone_ui_show(&s_snapshot, out == ANCS_OUT_SHOW);
        app_on_phone_notice();
        if (out == ANCS_OUT_SHOW && !(s_snapshot.flags & ANCS_FLAG_SILENT)) {
            chime_play(CHIME_PHONE);
        }
        memset(&s_snapshot, 0, sizeof(s_snapshot));
        /* Debug: NimBLE host task stack headroom (bytes never used) after a notice */
        ESP_LOGI(TAG, "stack headroom %s: %u bytes", pcTaskGetName(NULL), (unsigned)uxTaskGetStackHighWaterMark(NULL));
    } else if (out == ANCS_OUT_GONE) {
        phone_ui_gone(uid);
    }
}

bool ancs_client_on_notify(uint16_t conn, uint16_t attr, const uint8_t *data, uint16_t len)
{
    if (conn != s_link.conn || s_link.state != LINK_READY) {
        return false;
    }
    ancs_out_t out = ANCS_OUT_NONE;
    uint32_t uid = 0;
    if (attr == s_link.source_val) {
        ancs_source_t ev;
        if (!ancs_parse_source(data, len, &ev)) {
            return true;
        }
        uid = ev.uid;
        flow_lock();
        out = ancs_flow_on_source(&s_flow, &ev);
        flow_unlock();
    } else if (attr == s_link.data_val) {
        flow_lock();
        out = ancs_flow_on_data(&s_flow, data, len);
        if (out == ANCS_OUT_SHOW || out == ANCS_OUT_UPDATE) {
            s_snapshot = s_flow.notice;
        }
        flow_unlock();
    } else {
        return false;
    }
    deliver(out, uid);
    pump();
    return true;
}

static void notifications_ready(uint16_t conn)
{
    flow_lock();
    ancs_flow_init(&s_flow);
    s_flow_conn = conn;
    s_flow_control = s_link.control_val;
    flow_unlock();
    phone_ui_set_link(true);
    ble_link_ancs_link(conn, true);
    app_on_phone_notices_link(true);
    ESP_LOGI(TAG, "link %d: Claude notifications from the iPhone on", conn);
}

void ancs_client_on_disconnect(uint16_t conn)
{
    if (!link_forget(conn)) {
        return;
    }
    flow_lock();
    ancs_flow_init(&s_flow);
    s_flow_conn = BLE_HS_CONN_HANDLE_NONE;
    s_flow_control = 0;
    flow_unlock();
    phone_ui_set_link(false);   /* a notice on screen closes at once; its action buttons are gone */
    ble_link_ancs_link(conn, false);
    app_on_phone_notices_link(false);
    ESP_LOGI(TAG, "iPhone notifications off");
}

/* Shell / LVGL task (phone_ui.c, display lock held): the board closed that notice */
void ancs_client_close(uint32_t uid)
{
    if (s_flow_lock == NULL) {
        return;
    }
    flow_lock();
    ancs_flow_close(&s_flow, uid);
    flow_unlock();
}

static int on_action_written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr,
                             void *arg)
{
    uint32_t uid = (uint32_t)(uintptr_t)arg;
    if (error->status != 0) {
        ESP_LOGW(TAG, "the iPhone refused the action for %lu: status 0x%x", (unsigned long)uid, error->status);
    } else {
        ESP_LOGI(TAG, "the iPhone took the action for %lu", (unsigned long)uid);
    }
    phone_ui_action_result(uid, error->status == 0);
    return 0;
}

/* LVGL task (display lock held; lock order display -> flow) */
bool ancs_client_perform(uint32_t uid, uint8_t action)
{
    uint8_t cmd[6];
    if (s_flow_lock == NULL) {
        return false;
    }
    flow_lock();
    size_t n = ancs_flow_action(&s_flow, uid, action, cmd);
    uint16_t conn = s_flow_conn;
    uint16_t control = s_flow_control;
    flow_unlock();
    if (n == 0 || conn == BLE_HS_CONN_HANDLE_NONE) {
        ESP_LOGW(TAG, "action for %lu not sent: not the notice on screen, not offered, or no iPhone link",
                 (unsigned long)uid);
        return false;
    }
    int rc = ble_gattc_write_flat(conn, control, cmd, n, on_action_written, (void *)(uintptr_t)uid);
    ESP_LOGI(TAG, "%s action for %lu: %s (rc %d)", action == ANCS_ACTION_POSITIVE ? "positive" : "negative",
             (unsigned long)uid, rc == 0 ? "sent" : "NOT sent", rc);
    return rc == 0;
}
