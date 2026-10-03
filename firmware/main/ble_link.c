/*
 * BLE GATT server cho app iPhone.
 *
 * Service  A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A
 *   audio   ...0002  notify  : [seq u16][predictor i16][index u8][ADPCM...] (16 kHz mono)
 *   text    ...0003  write   : [flags u8][kind u8][UTF-8...]  flags bit0 = first chunk, bit1 = last chunk
 *                              kind 0 = subtitle (large), kind 1 = status line
 *   control ...0004  r/w/notify : 1 byte: 0 = board mic off, 1 = on
 */
#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "app.h"

static const char *TAG = "ble";

#define SVC_UUID(last) BLE_UUID128_INIT(0x0a, 0x9b, 0x8c, 0x7d, 0x6e, 0x5f, 0x8a, 0x9d, \
                                        0x1e, 0x4c, 0x2f, 0x3b, (last), 0x00, 0xc0, 0xa7)

static const ble_uuid128_t s_svc_uuid = SVC_UUID(0x01);
static const ble_uuid128_t s_audio_uuid = SVC_UUID(0x02);
static const ble_uuid128_t s_text_uuid = SVC_UUID(0x03);
static const ble_uuid128_t s_ctrl_uuid = SVC_UUID(0x04);

#define TEXT_FLAG_FIRST 0x01
#define TEXT_FLAG_LAST  0x02
#define TEXT_KIND_MAIN   0
#define TEXT_KIND_STATUS 1
#define TEXT_MAX         1024

static uint16_t s_audio_handle;
static uint16_t s_text_handle;
static uint16_t s_ctrl_handle;

static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static volatile bool s_audio_subscribed;
static uint8_t s_own_addr_type;

static char s_text_buf[TEXT_MAX + 1];
static size_t s_text_len;

static void start_advertising(void);

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
        if (kind == TEXT_KIND_STATUS) {
            ui_show_status(s_text_buf);
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

    if (attr_handle == s_ctrl_handle) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            uint8_t state = app_get_recording();
            return os_mbuf_append(ctxt->om, &state, 1) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            if (ble_hs_mbuf_to_flat(ctxt->om, buf, 1, &len) != 0 || len != 1 || buf[0] > REC_VI) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            app_request_recording((rec_lang_t)buf[0]);
            return 0;
        }
    } else if (attr_handle == s_text_handle && ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len) != 0) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
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
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_audio_handle,
            },
            {
                .uuid = &s_text_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_text_handle,
            },
            {
                .uuid = &s_ctrl_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_ctrl_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

static int gap_event(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            start_advertising();
            break;
        }
        s_conn_handle = event->connect.conn_handle;
        ESP_LOGI(TAG, "connected");
        /* 2M PHY + a connection interval that fits real-time audio without waking the radio too often */
        ble_gap_set_prefered_le_phy(s_conn_handle, BLE_GAP_LE_PHY_2M_MASK,
                                    BLE_GAP_LE_PHY_2M_MASK, BLE_GAP_LE_PHY_CODED_ANY);
        struct ble_gap_upd_params params = {
            .itvl_min = 24,   /* 30 ms: two 20 ms audio packets per event, half the radio wake-ups of 15 ms */
            .itvl_max = 36,   /* 45 ms */
            .latency = 0,
            .supervision_timeout = 400,
        };
        ble_gap_update_params(s_conn_handle, &params);
        app_on_connection_changed(true);
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnected, reason 0x%x", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_audio_subscribed = false;
        app_on_connection_changed(false);
        start_advertising();
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_audio_handle) {
            s_audio_subscribed = event->subscribe.cur_notify;
            ESP_LOGI(TAG, "audio notify %s", s_audio_subscribed ? "on" : "off");
        }
        break;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU %d", event->mtu.value);
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        start_advertising();
        break;

    default:
        break;
    }
    return 0;
}

static void start_advertising(void)
{
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

    const char *name = ble_svc_gap_device_name();
    struct ble_hs_adv_fields rsp = { 0 };
    rsp.name = (const uint8_t *)name;
    rsp.name_len = strlen(name);
    rsp.name_is_complete = 1;
    ble_gap_adv_rsp_set_fields(&rsp);

    struct ble_gap_adv_params adv = { 0 };
    adv.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "adv start rc=%d", rc);
    }
}

static void on_sync(void)
{
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
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(s_services));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(s_services));

    nimble_port_freertos_init(host_task);
}

bool ble_link_audio_ready(void)
{
    return s_conn_handle != BLE_HS_CONN_HANDLE_NONE && s_audio_subscribed;
}

uint16_t ble_link_payload_max(void)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        return 20;
    }
    return ble_att_mtu(s_conn_handle) - 3;
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
        int rc = ble_gatts_notify_custom(s_conn_handle, s_audio_handle, om);
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
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        ble_gatts_chr_updated(s_ctrl_handle);
    }
}
