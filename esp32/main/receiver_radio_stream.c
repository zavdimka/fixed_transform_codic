#include "receiver_radio_stream.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "board_pins.h"
#include "driver/parlio_tx.h"
#include "esp_attr.h"
#include "esp_cpu.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "radio_link.h"

#define RX_BATCH_SLOT_COUNT 32U
#define RX_BATCH_MAX_BYTES (RADIO_LINK_MAX_PAYLOAD + 4U)
#define RX_RECORD_MAX_BYTES 1024U
#define RX_RECENT_RECORD_COUNT 16U
#define RX_FRAME_SLOT_COUNT 3U
#define RX_FRAME_STRIPE_COUNT 45U
#define RX_DMA_BUFFER_COUNT 16U
#define RX_PARLIO_CLOCK_HZ (24U * 1000U * 1000U)
#define RX_COMPLETE_STRIPE_MASK ((UINT64_C(1) << RX_FRAME_STRIPE_COUNT) - 1U)
#define RX_FRAME_HOLD_US (100 * 1000)
#define RX_ASSEMBLER_POLL_MS 10U
#define RX_MIN_REPLACEMENT_STRIPES 10U
#define RX_MAX_FRAME_REPEATS 50U
#define RX_DIAGNOSTIC_INTERVAL_MS 10000U
#define RX_CPU_FREQ_MHZ 240U

#define RX_OUTPUT_FRAME_US 20000
typedef struct {
    uint16_t length;
    uint8_t data[RX_BATCH_MAX_BYTES];
} radio_batch_slot_t;

typedef struct {
    uint16_t crc;
    uint16_t sequence;
    uint16_t frame;
    uint8_t type;
    uint8_t stripe;
    uint8_t fragment;
} record_signature_t;

typedef struct {
    uint16_t frame_id;
    uint16_t record_size[RX_FRAME_STRIPE_COUNT];
    uint64_t stripe_mask;
    uint8_t record[RX_FRAME_STRIPE_COUNT][RX_RECORD_MAX_BYTES];
} decoded_frame_slot_t;

typedef struct {
    uint32_t seen;
    uint32_t suppressed;
    uint16_t last_frame_id;
    uint8_t last_stripes;
    uint64_t last_mask;
} candidate_scan_t;

static const char *TAG = "rx_stream";
static QueueHandle_t s_free_slots;
static QueueHandle_t s_ready_slots;
static QueueHandle_t s_free_frame_slots;
static QueueHandle_t s_complete_frames;
static radio_batch_slot_t *s_slots;
static decoded_frame_slot_t *s_frames;
static uint8_t *s_dma_buffers[RX_DMA_BUFFER_COUNT];
static parlio_tx_unit_handle_t s_tx_unit;
static TaskHandle_t s_replay_task_handle;
static atomic_bool s_started;
static atomic_uint_fast32_t s_radio_batches;
static atomic_uint_fast32_t s_radio_bytes;
static atomic_uint_fast32_t s_records;
static atomic_uint_fast32_t s_record_bytes;
static atomic_uint_fast32_t s_invalid_batches;
static atomic_uint_fast32_t s_invalid_records;
static atomic_uint_fast32_t s_duplicate_records;
static atomic_uint_fast32_t s_filtered_enhancement_records;
static atomic_uint_fast32_t s_filtered_other_records;
static atomic_uint_fast32_t s_queue_drops;
static atomic_uint_fast32_t s_assembled_records;
static atomic_uint_fast32_t s_completed_frames;
static atomic_uint_fast32_t s_incomplete_frames;
static atomic_uint_fast32_t s_replayed_frames;
static record_signature_t s_recent_records[RX_RECENT_RECORD_COUNT];
static uint8_t s_recent_record_index;
static uint8_t s_recent_record_count;
static atomic_uint_fast32_t s_parlio_errors;
static atomic_int s_last_error;
static volatile uint16_t s_diag_active_frame_id;
static volatile uint8_t s_diag_active_stripes;
static volatile uint8_t s_diag_repeated_passes;
static volatile uint64_t s_diag_active_mask;
static volatile uint16_t s_diag_candidate_frame_id;
static volatile uint8_t s_diag_candidate_stripes;
static volatile uint64_t s_diag_candidate_mask;
static volatile uint32_t s_diag_switches;
static volatile uint32_t s_diag_suppressed;
static volatile uint32_t s_diag_expired;
static volatile uint32_t s_diag_tx_us;
static volatile uint32_t s_diag_period_us;
static volatile uint32_t s_diag_max_period_us;
static volatile uint32_t s_diag_late_periods;
static volatile uint32_t s_completion_last_cycle;
static volatile uint32_t s_completion_max_gap_cycles;
static volatile uint8_t s_completion_count;
static volatile uint8_t s_completion_max_index;
static volatile uint32_t s_diag_pass_bytes;
static volatile uint32_t s_diag_max_record_gap_us;
static volatile uint8_t s_diag_max_gap_stripe;
static volatile uint16_t s_diag_max_gap_record_size;
static volatile uint32_t s_diag_worst_tx_us;
static volatile uint16_t s_diag_worst_frame_id;
static volatile uint8_t s_diag_worst_stripes;
static volatile uint32_t s_diag_worst_bytes;
static volatile uint32_t s_diag_worst_gap_us;
static volatile uint8_t s_diag_worst_gap_stripe;
static volatile uint16_t s_diag_worst_gap_record_size;

static uint16_t read_le16(const uint8_t *data)
{
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}
static bool frame_id_is_newer(uint16_t candidate, uint16_t reference)
{
    return (int16_t)(candidate - reference) > 0;
}


static uint16_t crc16_ccitt(const uint8_t *data, size_t size)
{
    uint16_t crc = 0xffff;
    while (size-- != 0) {
        uint8_t value = (uint8_t)((crc >> 8) ^ *data++);
        value ^= value >> 4;
        crc = (uint16_t)((crc << 8) ^ ((uint16_t)value << 12) ^
                         ((uint16_t)value << 5) ^ value);
    }
    return crc;
}

static bool record_is_valid(const uint8_t *record, size_t size)
{
    if (size < 20U || size > RX_RECORD_MAX_BYTES ||
        record[0] != 0xc5 || record[1] != 0x3a ||
        record[2] != 0x01 ||
        20U + read_le16(record + 16) != size) {
        return false;
    }
    return crc16_ccitt(record, size - 2U) ==
           read_le16(record + size - 2U);
}

static bool record_is_duplicate(const uint8_t *record, size_t size)
{
    const record_signature_t candidate = {
        .crc = read_le16(record + size - 2U),
        .sequence = read_le16(record + 4),
        .frame = read_le16(record + 6),
        .type = record[3],
        .stripe = record[10],
        .fragment = record[12],
    };
    for (uint8_t index = 0; index < s_recent_record_count; ++index) {
        const record_signature_t *recent = &s_recent_records[index];
        if (recent->crc == candidate.crc &&
            recent->sequence == candidate.sequence &&
            recent->frame == candidate.frame &&
            recent->type == candidate.type &&
            recent->stripe == candidate.stripe &&
            recent->fragment == candidate.fragment) {
            return true;
        }
    }
    s_recent_records[s_recent_record_index] = candidate;
    s_recent_record_index =
        (uint8_t)((s_recent_record_index + 1U) % RX_RECENT_RECORD_COUNT);
    if (s_recent_record_count < RX_RECENT_RECORD_COUNT) {
        ++s_recent_record_count;
    }
    return false;
}

// Return the useful HZU1 byte count. Some promiscuous-mode IDF revisions
// include the four-byte 802.11 FCS in sig_len, so up to four trailing bytes
// after the last complete record are deliberately ignored.
static size_t validated_batch_length(const uint8_t *payload, size_t size)
{
    if (payload == NULL || size < 26U || size > RX_BATCH_MAX_BYTES ||
        payload[0] != 'H' || payload[1] != 'Z' ||
        payload[2] != 'U' || payload[3] != 1) {
        return 0;
    }

    size_t offset = 4U;
    size_t logical_end = 0;
    uint32_t records = 0;
    while (offset + 2U <= size) {
        const size_t record_size = read_le16(payload + offset);
        if (record_size < 20U || record_size > RX_RECORD_MAX_BYTES ||
            offset + 2U + record_size > size) {
            break;
        }
        const uint8_t *record = payload + offset + 2U;
        if (record[0] != 0xc5 || record[1] != 0x3a ||
            record[2] != 0x01 ||
            20U + read_le16(record + 16) != record_size) {
            break;
        }
        offset += 2U + record_size;
        logical_end = offset;
        ++records;
    }
    if (records == 0 || size - logical_end > 4U) {
        return 0;
    }
    return logical_end;
}

void receiver_radio_stream_ingest(const uint8_t *payload,
                                  size_t payload_size,
                                  void *context)
{
    (void)context;
    if (!atomic_load_explicit(&s_started, memory_order_relaxed)) {
        return;
    }

    const size_t batch_length =
        validated_batch_length(payload, payload_size);
    if (batch_length == 0) {
        atomic_fetch_add_explicit(&s_invalid_batches, 1,
                                  memory_order_relaxed);
        return;
    }

    uint16_t slot_index;
    if (xQueueReceive(s_free_slots, &slot_index, 0) != pdTRUE) {
        atomic_fetch_add_explicit(&s_queue_drops, 1,
                                  memory_order_relaxed);
        return;
    }

    radio_batch_slot_t *slot = &s_slots[slot_index];
    memcpy(slot->data, payload, batch_length);
    slot->length = (uint16_t)batch_length;
    if (xQueueSend(s_ready_slots, &slot_index, 0) != pdTRUE) {
        atomic_fetch_add_explicit(&s_queue_drops, 1,
                                  memory_order_relaxed);
        (void)xQueueSend(s_free_slots, &slot_index, 0);
        return;
    }
    atomic_fetch_add_explicit(&s_radio_batches, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s_radio_bytes, batch_length,
                              memory_order_relaxed);
}

static bool IRAM_ATTR parlio_trans_done_callback(
    parlio_tx_unit_handle_t tx_unit,
    const parlio_tx_done_event_data_t *event_data, void *user_context)
{
    (void)tx_unit;
    (void)event_data;
    const uint32_t now_cycle = esp_cpu_get_cycle_count();
    const uint32_t gap_cycles = now_cycle - s_completion_last_cycle;
    const uint8_t completion_index = s_completion_count++;
    s_completion_last_cycle = now_cycle;
    if (gap_cycles > s_completion_max_gap_cycles) {
        s_completion_max_gap_cycles = gap_cycles;
        s_completion_max_index = completion_index;
    }

    BaseType_t high_priority_task_woken = pdFALSE;
    vTaskNotifyGiveFromISR((TaskHandle_t)user_context,
                           &high_priority_task_woken);
    return high_priority_task_woken == pdTRUE;
}

static esp_err_t wait_for_dma(uint32_t in_flight)
{
    if (in_flight == 0) {
        return ESP_OK;
    }
    const esp_err_t error = parlio_tx_unit_wait_all_done(s_tx_unit, -1);
    if (error != ESP_OK) {
        atomic_fetch_add_explicit(&s_parlio_errors, 1,
                                  memory_order_relaxed);
        atomic_store_explicit(&s_last_error, error, memory_order_relaxed);
    }
    // Completion callbacks are also used as ring-buffer credits.
    (void)ulTaskNotifyTake(pdTRUE, 0);
    return error;
}

static bool acquire_frame_slot(uint16_t *frame_index)
{
    if (xQueueReceive(s_free_frame_slots, frame_index, 0) == pdTRUE) {
        return true;
    }
    // Prefer the newest complete frame when the producer gets ahead.
    return xQueueReceive(s_complete_frames, frame_index, 0) == pdTRUE;
}

static void release_frame_slot(uint16_t frame_index)
{
    (void)xQueueSend(s_free_frame_slots, &frame_index, portMAX_DELAY);
}

static uint8_t frame_stripe_count(uint16_t frame_index)
{
    uint64_t mask = s_frames[frame_index].stripe_mask;
    uint8_t count = 0;
    while (mask != 0) {
        mask &= mask - 1U;
        ++count;
    }
    return count;
}

static bool take_newest_display_candidate(bool require_valid_frame,
                                          uint16_t *frame_index,
                                          candidate_scan_t *scan)
{
    bool found = false;
    uint16_t candidate;
    while (xQueueReceive(s_complete_frames, &candidate, 0) == pdTRUE) {
        const uint8_t stripes = frame_stripe_count(candidate);
        ++scan->seen;
        scan->last_frame_id = s_frames[candidate].frame_id;
        scan->last_stripes = stripes;
        scan->last_mask = s_frames[candidate].stripe_mask;
        if (require_valid_frame && stripes < RX_MIN_REPLACEMENT_STRIPES) {
            ++scan->suppressed;
            release_frame_slot(candidate);
            continue;
        }
        if (found) {
            release_frame_slot(*frame_index);
        }
        *frame_index = candidate;
        found = true;
    }
    return found;
}

static void frame_diagnostics_task(void *argument)
{
    (void)argument;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(RX_DIAGNOSTIC_INTERVAL_MS));
        ESP_LOGI(TAG,
                 "frame diag active=%u stripes=%u mask=%011llx repeat=%u "
                 "candidate=%u/%u mask=%011llx switch=%lu suppress=%lu "
                 "expire=%lu tx=%luus/%luB gap=%luus(s%u/%uB) "
                 "period=%luus max_period=%luus late=%lu "
                 "worst=%luus f%u/%u %luB gap=%luus(s%u/%uB) queued=%u",
                 s_diag_active_frame_id, s_diag_active_stripes,
                 (unsigned long long)s_diag_active_mask,
                 s_diag_repeated_passes, s_diag_candidate_frame_id,
                 s_diag_candidate_stripes,
                 (unsigned long long)s_diag_candidate_mask,
                 (unsigned long)s_diag_switches,
                 (unsigned long)s_diag_suppressed,
                 (unsigned long)s_diag_expired,
                 (unsigned long)s_diag_tx_us,
                 (unsigned long)s_diag_pass_bytes,
                 (unsigned long)s_diag_max_record_gap_us,
                 s_diag_max_gap_stripe,
                 s_diag_max_gap_record_size,
                 (unsigned long)s_diag_period_us,
                 (unsigned long)s_diag_max_period_us,
                 (unsigned long)s_diag_late_periods,
                 (unsigned long)s_diag_worst_tx_us,
                 s_diag_worst_frame_id,
                 s_diag_worst_stripes,
                 (unsigned long)s_diag_worst_bytes,
                 (unsigned long)s_diag_worst_gap_us,
                 s_diag_worst_gap_stripe,
                 s_diag_worst_gap_record_size,
                 (unsigned)uxQueueMessagesWaiting(s_complete_frames));
    }
}

static void publish_complete_frame(uint16_t frame_index)
{
    if (xQueueSend(s_complete_frames, &frame_index, 0) == pdTRUE) {
        return;
    }
    uint16_t stale_index;
    if (xQueueReceive(s_complete_frames, &stale_index, 0) == pdTRUE) {
        release_frame_slot(stale_index);
    }
    if (xQueueSend(s_complete_frames, &frame_index, 0) != pdTRUE) {
        release_frame_slot(frame_index);
        atomic_fetch_add_explicit(&s_queue_drops, 1,
                                  memory_order_relaxed);
    }
}

static void publish_assembled_frame(uint16_t frame_index)
{
    decoded_frame_slot_t *frame = &s_frames[frame_index];
    if (frame->stripe_mask == 0) {
        release_frame_slot(frame_index);
        return;
    }

    if (frame->stripe_mask == RX_COMPLETE_STRIPE_MASK) {
        atomic_fetch_add_explicit(&s_completed_frames, 1,
                                  memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&s_incomplete_frames, 1,
                                  memory_order_relaxed);
    }
    publish_complete_frame(frame_index);
}

static void assembler_task(void *argument)
{
    (void)argument;
    bool assembling = false;
    uint16_t assembly_index = 0;
    uint16_t assembly_frame_id = 0;
    bool closed_frame_valid = false;
    uint16_t closed_frame_id = 0;
    int64_t last_progress_us = 0;
    for (;;) {
        uint16_t slot_index;
        if (xQueueReceive(s_ready_slots, &slot_index,
                          pdMS_TO_TICKS(RX_ASSEMBLER_POLL_MS)) != pdTRUE) {
            if (assembling) {
                if (last_progress_us != 0 &&
                    esp_timer_get_time() - last_progress_us >=
                        RX_FRAME_HOLD_US) {
                    publish_assembled_frame(assembly_index);
                    assembling = false;
                    closed_frame_id = assembly_frame_id;
                    closed_frame_valid = true;
                }
            }
            continue;
        }
        radio_batch_slot_t *slot = &s_slots[slot_index];
        size_t offset = 4U;
        while (offset + 2U <= slot->length) {
            const size_t record_size = read_le16(slot->data + offset);
            const uint8_t *record = slot->data + offset + 2U;
            offset += 2U + record_size;
            if (!record_is_valid(record, record_size)) {
                atomic_fetch_add_explicit(&s_invalid_records, 1,
                                          memory_order_relaxed);
                continue;
            }
            if (record_is_duplicate(record, record_size)) {
                atomic_fetch_add_explicit(&s_duplicate_records, 1,
                                          memory_order_relaxed);
                continue;
            }
            // The radio link always carries the complete PC-compatible
            // stream. This FPGA build accepts only base records, so strip
            // optional layers here before frame storage and PARLIO replay.
            if (record[3] == 0x11U) {
                atomic_fetch_add_explicit(
                    &s_filtered_enhancement_records, 1,
                    memory_order_relaxed);
                continue;
            }
            if (record[3] != 0x10U) {
                atomic_fetch_add_explicit(&s_filtered_other_records, 1,
                                          memory_order_relaxed);
                continue;
            }
            if (record[10] >= RX_FRAME_STRIPE_COUNT) {
                atomic_fetch_add_explicit(&s_invalid_records, 1,
                                          memory_order_relaxed);
                continue;
            }

            const uint16_t frame_id = read_le16(record + 6U);
            const int64_t now_us = esp_timer_get_time();
            const bool epoch_timed_out = last_progress_us != 0 &&
                now_us - last_progress_us >= RX_FRAME_HOLD_US;

            // A restarted transmitter begins again from a small frame ID.
            // Do not let a previous session's closed frame reject that new
            // epoch forever. Only accepted records refresh last_progress_us,
            // so a continuous stream of stale IDs still reacquires after the
            // same outage interval.
            if (assembling && epoch_timed_out) {
                publish_assembled_frame(assembly_index);
                assembling = false;
                closed_frame_id = assembly_frame_id;
                closed_frame_valid = true;
            }

            bool start_new_frame = false;
            if (!assembling) {
                if (closed_frame_valid &&
                    !frame_id_is_newer(frame_id, closed_frame_id) &&
                    !epoch_timed_out) {
                    continue;
                }
                if (epoch_timed_out) {
                    closed_frame_valid = false;
                }
                start_new_frame = true;
            } else if (frame_id != assembly_frame_id) {
                if (!frame_id_is_newer(frame_id, assembly_frame_id)) {
                    continue;
                }
                // A new frame closes the old one. Missing stripes remain
                // absent so FPGA concealment reflects real radio loss.
                publish_assembled_frame(assembly_index);
                closed_frame_id = assembly_frame_id;
                closed_frame_valid = true;
                start_new_frame = true;
            }
            if (start_new_frame) {
                assembly_frame_id = frame_id;
                assembling = acquire_frame_slot(&assembly_index);
                if (assembling) {
                    decoded_frame_slot_t *frame = &s_frames[assembly_index];
                    frame->frame_id = frame_id;
                    frame->stripe_mask = 0;
                }
            }
            if (!assembling) {
                continue;
            }

            last_progress_us = now_us;
            decoded_frame_slot_t *frame = &s_frames[assembly_index];
            const uint8_t stripe = record[10];
            const uint64_t stripe_bit = UINT64_C(1) << stripe;
            if ((frame->stripe_mask & stripe_bit) != 0) {
                continue;
            }
            memcpy(frame->record[stripe], record, record_size);
            frame->record_size[stripe] = (uint16_t)record_size;
            frame->stripe_mask |= stripe_bit;
            atomic_fetch_add_explicit(&s_assembled_records, 1,
                                      memory_order_relaxed);
        }
        if (xQueueSend(s_free_slots, &slot_index, portMAX_DELAY) != pdTRUE) {
            atomic_fetch_add_explicit(&s_queue_drops, 1,
                                      memory_order_relaxed);
        }
    }
}

static void replay_task(void *argument)
{
    (void)argument;
    const parlio_transmit_config_t transmit_config = {
        .idle_value = 0,
    };
    uint16_t active_index;
    if (xQueueReceive(s_complete_frames, &active_index,
                      portMAX_DELAY) != pdTRUE) {
        vTaskDelete(NULL);
        return;
    }
    uint8_t repeated_passes = 0;
    int64_t previous_pass_start_us = 0;

    for (;;) {
        const int64_t pass_start_us = esp_timer_get_time();
        const int64_t pass_period_us = previous_pass_start_us == 0
            ? 0 : pass_start_us - previous_pass_start_us;
        previous_pass_start_us = pass_start_us;
        if (pass_period_us > s_diag_max_period_us) {
            s_diag_max_period_us = (uint32_t)pass_period_us;
        }
        if (pass_period_us > 25000) {
            ++s_diag_late_periods;
        }
        decoded_frame_slot_t *frame = &s_frames[active_index];
        uint32_t in_flight = 0;
        uint32_t dma_index = 0;
        uint32_t pass_bytes = 0;
        uint8_t submission_count = 0;
        uint8_t submitted_stripe[RX_FRAME_STRIPE_COUNT] = {0};
        uint16_t submitted_size[RX_FRAME_STRIPE_COUNT] = {0};
        s_completion_count = 0;
        s_completion_max_gap_cycles = 0;
        s_completion_max_index = 0;
        s_completion_last_cycle = esp_cpu_get_cycle_count();
        esp_err_t error = ESP_OK;
        for (uint8_t stripe = 0; stripe < RX_FRAME_STRIPE_COUNT; ++stripe) {
            if ((frame->stripe_mask & (UINT64_C(1) << stripe)) == 0) {
                continue;
            }
            if (in_flight == RX_DMA_BUFFER_COUNT) {
                // Reuse the oldest DMA buffer as soon as its transaction
                // completes. Queued records keep PARLIO running meanwhile.
                (void)ulTaskNotifyTake(pdFALSE, portMAX_DELAY);
                --in_flight;
            }
            const size_t record_size = frame->record_size[stripe];
            submitted_stripe[submission_count] = stripe;
            submitted_size[submission_count] = (uint16_t)record_size;
            memcpy(s_dma_buffers[dma_index], frame->record[stripe],
                   record_size);
            error = parlio_tx_unit_transmit(
                s_tx_unit, s_dma_buffers[dma_index], record_size * 8U,
                &transmit_config);
            if (error != ESP_OK) {
                atomic_fetch_add_explicit(&s_parlio_errors, 1,
                                          memory_order_relaxed);
                atomic_store_explicit(&s_last_error, error,
                                      memory_order_relaxed);
                break;
            }
            ++in_flight;
            ++submission_count;
            pass_bytes += record_size;
            dma_index = (dma_index + 1U) % RX_DMA_BUFFER_COUNT;
            atomic_fetch_add_explicit(&s_records, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&s_record_bytes, record_size,
                                      memory_order_relaxed);
        }
        if (error == ESP_OK) {
            error = wait_for_dma(in_flight);
        } else {
            (void)wait_for_dma(in_flight);
        }
        if (error == ESP_OK) {
            atomic_fetch_add_explicit(&s_replayed_frames, 1,
                                      memory_order_relaxed);
        }


        // A partial frame has fewer PARLIO transactions and can otherwise
        // finish early. Keep one source selection for a complete 50 Hz output
        // interval before considering a queued replacement.
        const int64_t pass_elapsed_us = esp_timer_get_time() - pass_start_us;
        const uint8_t max_gap_index = s_completion_max_index;
        const uint32_t max_record_gap_us =
            s_completion_max_gap_cycles / RX_CPU_FREQ_MHZ;
        const uint8_t max_gap_stripe = max_gap_index < submission_count
            ? submitted_stripe[max_gap_index] : UINT8_MAX;
        const uint16_t max_gap_record_size = max_gap_index < submission_count
            ? submitted_size[max_gap_index] : 0;
        const uint8_t transmitted_stripes = submission_count;
        if ((uint32_t)pass_elapsed_us > s_diag_worst_tx_us) {
            s_diag_worst_tx_us = (uint32_t)pass_elapsed_us;
            s_diag_worst_frame_id = frame->frame_id;
            s_diag_worst_stripes = transmitted_stripes;
            s_diag_worst_bytes = pass_bytes;
            s_diag_worst_gap_us = max_record_gap_us;
            s_diag_worst_gap_stripe = max_gap_stripe;
            s_diag_worst_gap_record_size = max_gap_record_size;
        }
        s_diag_pass_bytes = pass_bytes;
        s_diag_max_record_gap_us = max_record_gap_us;
        s_diag_max_gap_stripe = max_gap_stripe;
        s_diag_max_gap_record_size = max_gap_record_size;

        // A complete frame is paced by the FPGA's stripe-bank backpressure.
        // Adding a software delay here lets the feed phase drift against the
        // HDMI raster and eventually creates a near-frame-long PAR_CLK stall.
        if (transmitted_stripes < RX_FRAME_STRIPE_COUNT
            && pass_elapsed_us < RX_OUTPUT_FRAME_US) {
            const uint32_t wait_ms =
                (uint32_t)(RX_OUTPUT_FRAME_US - pass_elapsed_us + 999) / 1000U;
            vTaskDelay(pdMS_TO_TICKS(wait_ms));
        }
        const bool active_is_valid =
            frame_stripe_count(active_index) >= RX_MIN_REPLACEMENT_STRIPES;
        const bool repetition_limit_reached =
            repeated_passes >= RX_MAX_FRAME_REPEATS;
        uint16_t newest;
        candidate_scan_t scan = {0};
        if (take_newest_display_candidate(
                active_is_valid && !repetition_limit_reached, &newest,
                &scan)) {
            release_frame_slot(active_index);
            active_index = newest;
            repeated_passes = 0;
            ++s_diag_switches;
        } else if (repetition_limit_reached) {
            // Do not freeze a previously valid picture indefinitely. With no
            // queued replacement, stopping PARLIO replay makes the FPGA show
            // neutral gray. The next frame may contain only one stripe: once
            // there is no valid old picture, freshness wins over completeness.
            ++s_diag_expired;
            ESP_LOGW(TAG, "frame expired id=%u stripes=%u mask=%011llx",
                     frame->frame_id, frame_stripe_count(active_index),
                     (unsigned long long)frame->stripe_mask);
            release_frame_slot(active_index);
            if (xQueueReceive(s_complete_frames, &active_index,
                              portMAX_DELAY) != pdTRUE) {
                vTaskDelete(NULL);
                return;
            }
            repeated_passes = 0;
        } else {
            ++repeated_passes;
        }
        s_diag_suppressed += scan.suppressed;
        if (scan.seen != 0) {
            s_diag_candidate_frame_id = scan.last_frame_id;
            s_diag_candidate_stripes = scan.last_stripes;
            s_diag_candidate_mask = scan.last_mask;
        }
        s_diag_active_frame_id = s_frames[active_index].frame_id;
        s_diag_active_stripes = frame_stripe_count(active_index);
        s_diag_active_mask = s_frames[active_index].stripe_mask;
        s_diag_repeated_passes = repeated_passes;
        s_diag_tx_us = (uint32_t)pass_elapsed_us;
        s_diag_period_us = (uint32_t)pass_period_us;


    }
}
esp_err_t receiver_radio_stream_start(void)
{
    bool expected = false;
    if (!atomic_compare_exchange_strong(&s_started, &expected, true)) {
        return ESP_ERR_INVALID_STATE;
    }

    s_free_slots = xQueueCreate(RX_BATCH_SLOT_COUNT, sizeof(uint16_t));
    s_ready_slots = xQueueCreate(RX_BATCH_SLOT_COUNT, sizeof(uint16_t));
    s_free_frame_slots = xQueueCreate(RX_FRAME_SLOT_COUNT, sizeof(uint16_t));
    s_complete_frames = xQueueCreate(RX_FRAME_SLOT_COUNT - 1U,
                                     sizeof(uint16_t));
    // The promiscuous callback writes these slots directly. Keeping its
    // short queue in internal RAM avoids a PSRAM copy on the Wi-Fi task while
    // the much larger assembled-frame store remains in external memory.
    s_slots = heap_caps_calloc(RX_BATCH_SLOT_COUNT, sizeof(*s_slots),
                               MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    s_frames = heap_caps_calloc(RX_FRAME_SLOT_COUNT, sizeof(*s_frames),
                                MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_free_slots == NULL || s_ready_slots == NULL ||
        s_free_frame_slots == NULL || s_complete_frames == NULL ||
        s_slots == NULL || s_frames == NULL) {
        atomic_store(&s_started, false);
        return ESP_ERR_NO_MEM;
    }
    for (uint16_t index = 0; index < RX_BATCH_SLOT_COUNT; ++index) {
        (void)xQueueSend(s_free_slots, &index, portMAX_DELAY);
    }
    for (uint16_t index = 0; index < RX_FRAME_SLOT_COUNT; ++index) {
        (void)xQueueSend(s_free_frame_slots, &index, portMAX_DELAY);
    }
    for (size_t index = 0; index < RX_DMA_BUFFER_COUNT; ++index) {
        s_dma_buffers[index] = heap_caps_aligned_alloc(
            32, RX_RECORD_MAX_BYTES,
            MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
        if (s_dma_buffers[index] == NULL) {
            atomic_store(&s_started, false);
            return ESP_ERR_NO_MEM;
        }
    }

    const parlio_tx_unit_config_t config = {
        .clk_src = PARLIO_CLK_SRC_EXTERNAL,
        .clk_in_gpio_num = BOARD_PIN_PAR_CLK,
        .input_clk_src_freq_hz = RX_PARLIO_CLOCK_HZ,
        .output_clk_freq_hz = RX_PARLIO_CLOCK_HZ,
        .data_width = 4,
        .data_gpio_nums = {
            BOARD_PIN_PAR_D0, BOARD_PIN_PAR_D1,
            BOARD_PIN_PAR_D2, BOARD_PIN_PAR_D3,
        },
        .clk_out_gpio_num = -1,
        .valid_gpio_num = BOARD_PIN_PAR_CS,
        .trans_queue_depth = RX_DMA_BUFFER_COUNT,
        .max_transfer_size = RX_RECORD_MAX_BYTES,
        .dma_burst_size = 32,
        .shift_edge = PARLIO_SHIFT_EDGE_NEG,
        .bit_pack_order = PARLIO_BIT_PACK_ORDER_MSB,
    };
    esp_err_t error = parlio_new_tx_unit(&config, &s_tx_unit);
    if (error == ESP_OK) {
        error = parlio_tx_unit_enable(s_tx_unit);
    }
    if (error != ESP_OK) {
        atomic_store(&s_started, false);
        atomic_store(&s_last_error, error);
        return error;
    }
    if (xTaskCreate(assembler_task, "rx_assemble", 4096, NULL, 19, NULL) !=
            pdPASS ||
        xTaskCreate(replay_task, "rx_fpga_replay", 4096, NULL, 24,
                    &s_replay_task_handle) !=
            pdPASS ||
        xTaskCreate(frame_diagnostics_task, "rx_frame_diag", 3072, NULL,
                    5, NULL) !=
            pdPASS) {
        atomic_store(&s_started, false);
        return ESP_ERR_NO_MEM;
    }

    const parlio_tx_event_callbacks_t callbacks = {
        .on_trans_done = parlio_trans_done_callback,
    };
    error = parlio_tx_unit_register_event_callbacks(
        s_tx_unit, &callbacks, s_replay_task_handle);
    if (error != ESP_OK) {
        atomic_store(&s_started, false);
        return error;
    }
    radio_link_set_rx_handler(receiver_radio_stream_ingest, NULL);
    atomic_store(&s_last_error, ESP_OK);
    ESP_LOGI(TAG, "live radio frame buffer ready: %u batch slots, "
                  "%u frame slots, %u DMA buffers",
             RX_BATCH_SLOT_COUNT, RX_FRAME_SLOT_COUNT, RX_DMA_BUFFER_COUNT);
    return ESP_OK;
}

void receiver_radio_stream_get_status(receiver_radio_stream_status_t *status)
{
    if (status == NULL) {
        return;
    }
    *status = (receiver_radio_stream_status_t) {
        .running = atomic_load_explicit(&s_started, memory_order_relaxed),
        .radio_batches = atomic_load_explicit(
            &s_radio_batches, memory_order_relaxed),
        .radio_bytes = atomic_load_explicit(
            &s_radio_bytes, memory_order_relaxed),
        .records = atomic_load_explicit(&s_records, memory_order_relaxed),
        .record_bytes = atomic_load_explicit(
            &s_record_bytes, memory_order_relaxed),
        .invalid_batches = atomic_load_explicit(
            &s_invalid_batches, memory_order_relaxed),
        .invalid_records = atomic_load_explicit(
            &s_invalid_records, memory_order_relaxed),
        .duplicate_records = atomic_load_explicit(
            &s_duplicate_records, memory_order_relaxed),
        .filtered_enhancement_records = atomic_load_explicit(
            &s_filtered_enhancement_records, memory_order_relaxed),
        .filtered_other_records = atomic_load_explicit(
            &s_filtered_other_records, memory_order_relaxed),
        .queue_drops = atomic_load_explicit(
            &s_queue_drops, memory_order_relaxed),
        .assembled_records = atomic_load_explicit(
            &s_assembled_records, memory_order_relaxed),
        .completed_frames = atomic_load_explicit(
            &s_completed_frames, memory_order_relaxed),
        .incomplete_frames = atomic_load_explicit(
            &s_incomplete_frames, memory_order_relaxed),
        .replayed_frames = atomic_load_explicit(
            &s_replayed_frames, memory_order_relaxed),
        .parlio_errors = atomic_load_explicit(
            &s_parlio_errors, memory_order_relaxed),
        .last_error = atomic_load_explicit(
            &s_last_error, memory_order_relaxed),
    };
}

void receiver_radio_stream_print_status(void)
{
    receiver_radio_stream_status_t status = {0};
    receiver_radio_stream_get_status(&status);
    printf("decoder live running=%u batches=%lu bytes=%lu records=%lu "
           "record_bytes=%lu invalid_batches=%lu invalid_records=%lu dup=%lu "
           "filtered_enh=%lu filtered_other=%lu "
           "drops=%lu assembled=%lu complete=%lu incomplete=%lu replay=%lu "
           "parlio_errors=%lu result=%s\n",
           status.running, (unsigned long)status.radio_batches,
           (unsigned long)status.radio_bytes,
           (unsigned long)status.records,
           (unsigned long)status.record_bytes,
           (unsigned long)status.invalid_batches,
           (unsigned long)status.invalid_records,
           (unsigned long)status.duplicate_records,
           (unsigned long)status.filtered_enhancement_records,
           (unsigned long)status.filtered_other_records,
           (unsigned long)status.queue_drops,
           (unsigned long)status.assembled_records,
           (unsigned long)status.completed_frames,
           (unsigned long)status.incomplete_frames,
           (unsigned long)status.replayed_frames,
           (unsigned long)status.parlio_errors,
           esp_err_to_name(status.last_error));
}
