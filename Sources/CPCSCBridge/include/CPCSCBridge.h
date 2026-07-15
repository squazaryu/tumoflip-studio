#ifndef TUMOCARD_PCSC_BRIDGE_H
#define TUMOCARD_PCSC_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TC_PCSC_MAX_ATR_SIZE 33U

typedef struct TCPCSCSession TCPCSCSession;

typedef struct {
    uint32_t active_protocol;
    uint8_t atr[TC_PCSC_MAX_ATR_SIZE];
    uint32_t atr_length;
} TCPCSCConnectionInfo;

TCPCSCSession* tc_pcsc_session_create(int32_t* error_code);
void tc_pcsc_session_destroy(TCPCSCSession* session);

int32_t tc_pcsc_list_readers(
    TCPCSCSession* session,
    char* readers,
    uint32_t* readers_length);

int32_t tc_pcsc_connect(
    TCPCSCSession* session,
    const char* reader,
    TCPCSCConnectionInfo* info);

int32_t tc_pcsc_status(TCPCSCSession* session, TCPCSCConnectionInfo* info);
void tc_pcsc_disconnect(TCPCSCSession* session);

int32_t tc_pcsc_transmit(
    TCPCSCSession* session,
    const uint8_t* command,
    uint32_t command_length,
    uint8_t* response,
    uint32_t* response_length);

bool tc_pcsc_is_success(int32_t code);
bool tc_pcsc_is_no_reader(int32_t code);
bool tc_pcsc_is_no_card(int32_t code);
bool tc_pcsc_is_card_removed(int32_t code);
const char* tc_pcsc_error_description(int32_t code);

#ifdef __cplusplus
}
#endif

#endif
