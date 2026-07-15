#include "CPCSCBridge.h"

#include <PCSC/pcsclite.h>
#include <PCSC/winscard.h>
#include <stdlib.h>
#include <string.h>

struct TCPCSCSession {
    SCARDCONTEXT context;
    SCARDHANDLE card;
    uint32_t active_protocol;
    bool connected;
};

static void tc_pcsc_clear_info(TCPCSCConnectionInfo* info) {
    if(info) memset(info, 0, sizeof(*info));
}

static int32_t tc_pcsc_fill_status(TCPCSCSession* session, TCPCSCConnectionInfo* info) {
    if(!session || !session->connected || !info) return SCARD_E_INVALID_PARAMETER;

    tc_pcsc_clear_info(info);
    uint32_t reader_length = 0;
    uint32_t state = 0;
    uint32_t atr_length = TC_PCSC_MAX_ATR_SIZE;
    int32_t result = SCardStatus(
        session->card,
        NULL,
        &reader_length,
        &state,
        &info->active_protocol,
        info->atr,
        &atr_length);
    if(result == SCARD_S_SUCCESS) {
        info->atr_length = atr_length;
        session->active_protocol = info->active_protocol;
    }
    return result;
}

TCPCSCSession* tc_pcsc_session_create(int32_t* error_code) {
    if(error_code) *error_code = SCARD_F_INTERNAL_ERROR;

    TCPCSCSession* session = calloc(1, sizeof(TCPCSCSession));
    if(!session) {
        if(error_code) *error_code = SCARD_E_NO_MEMORY;
        return NULL;
    }

    const int32_t result =
        SCardEstablishContext(SCARD_SCOPE_USER, NULL, NULL, &session->context);
    if(result != SCARD_S_SUCCESS) {
        free(session);
        if(error_code) *error_code = result;
        return NULL;
    }

    if(error_code) *error_code = SCARD_S_SUCCESS;
    return session;
}

void tc_pcsc_session_destroy(TCPCSCSession* session) {
    if(!session) return;
    tc_pcsc_disconnect(session);
    SCardReleaseContext(session->context);
    free(session);
}

int32_t tc_pcsc_list_readers(
    TCPCSCSession* session,
    char* readers,
    uint32_t* readers_length) {
    if(!session || !readers_length) return SCARD_E_INVALID_PARAMETER;
    return SCardListReaders(session->context, NULL, readers, readers_length);
}

int32_t tc_pcsc_connect(
    TCPCSCSession* session,
    const char* reader,
    TCPCSCConnectionInfo* info) {
    if(!session || !reader || !info) return SCARD_E_INVALID_PARAMETER;
    tc_pcsc_disconnect(session);
    tc_pcsc_clear_info(info);

    int32_t result = SCardConnect(
        session->context,
        reader,
        SCARD_SHARE_SHARED,
        SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1,
        &session->card,
        &session->active_protocol);
    if(result != SCARD_S_SUCCESS) return result;

    session->connected = true;
    result = tc_pcsc_fill_status(session, info);
    if(result != SCARD_S_SUCCESS) tc_pcsc_disconnect(session);
    return result;
}

int32_t tc_pcsc_status(TCPCSCSession* session, TCPCSCConnectionInfo* info) {
    return tc_pcsc_fill_status(session, info);
}

void tc_pcsc_disconnect(TCPCSCSession* session) {
    if(!session || !session->connected) return;
    SCardDisconnect(session->card, SCARD_LEAVE_CARD);
    session->card = 0;
    session->active_protocol = SCARD_PROTOCOL_UNDEFINED;
    session->connected = false;
}

int32_t tc_pcsc_transmit(
    TCPCSCSession* session,
    const uint8_t* command,
    uint32_t command_length,
    uint8_t* response,
    uint32_t* response_length) {
    if(!session || !session->connected || !command || command_length == 0 || !response ||
       !response_length) {
        return SCARD_E_INVALID_PARAMETER;
    }

    const SCARD_IO_REQUEST* send_pci = NULL;
    if(session->active_protocol == SCARD_PROTOCOL_T0) {
        send_pci = SCARD_PCI_T0;
    } else if(session->active_protocol == SCARD_PROTOCOL_T1) {
        send_pci = SCARD_PCI_T1;
    } else {
        return SCARD_E_PROTO_MISMATCH;
    }

    return SCardTransmit(
        session->card,
        send_pci,
        command,
        command_length,
        NULL,
        response,
        response_length);
}

bool tc_pcsc_is_success(int32_t code) {
    return code == SCARD_S_SUCCESS;
}

bool tc_pcsc_is_no_reader(int32_t code) {
    return code == (int32_t)SCARD_E_NO_READERS_AVAILABLE ||
           code == (int32_t)SCARD_E_UNKNOWN_READER ||
           code == (int32_t)SCARD_E_READER_UNAVAILABLE;
}

bool tc_pcsc_is_no_card(int32_t code) {
    return code == (int32_t)SCARD_E_NO_SMARTCARD || code == (int32_t)SCARD_E_NOT_READY;
}

bool tc_pcsc_is_card_removed(int32_t code) {
    return code == (int32_t)SCARD_W_REMOVED_CARD ||
           code == (int32_t)SCARD_W_UNPOWERED_CARD ||
           code == (int32_t)SCARD_W_RESET_CARD || tc_pcsc_is_no_card(code);
}

const char* tc_pcsc_error_description(int32_t code) {
    switch((uint32_t)code) {
    case SCARD_S_SUCCESS:
        return "Success";
    case SCARD_E_NO_READERS_AVAILABLE:
        return "No smart-card reader is available";
    case SCARD_E_UNKNOWN_READER:
        return "The reader is no longer available";
    case SCARD_E_READER_UNAVAILABLE:
        return "The reader cannot be reached";
    case SCARD_E_NO_SMARTCARD:
        return "No card is present";
    case SCARD_E_NOT_READY:
        return "The card is not ready";
    case SCARD_E_SHARING_VIOLATION:
        return "The card is in use by another process";
    case SCARD_E_PROTO_MISMATCH:
        return "The card protocol is unsupported";
    case SCARD_E_TIMEOUT:
        return "The reader timed out";
    case SCARD_W_REMOVED_CARD:
        return "The card was removed";
    case SCARD_W_RESET_CARD:
        return "The card was reset";
    case SCARD_E_NO_SERVICE:
    case SCARD_E_SERVICE_STOPPED:
        return "The macOS smart-card service is unavailable";
    default:
        return "PC/SC communication failed";
    }
}
