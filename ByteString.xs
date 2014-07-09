#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#define JSON2_STACK_CELL_SIZE 1022
struct StackCell_t {
    struct StackCell_t *prev, *next;
    SV* slot[JSON2_STACK_CELL_SIZE];
};

MODULE = JSON::XS::ByteString		PACKAGE = JSON::XS::ByteString		

#define SHIFT_AND_EXTEND_JSON2_STACK \
    if( p == curr->slot + JSON2_STACK_CELL_SIZE ){ \
        if( !curr->next ){ \
            struct StackCell_t *next; \
            Newx(next, 1, struct StackCell_t); \
            curr->next = next; \
            next->prev = curr; \
            next->next = NULL; \
        } \
        tail = curr = curr->next; \
        p = curr->slot; \
    }

void
encode_utf8(SV *data)
    CODE:
        struct StackCell_t head, *tail, *curr;
        SV ** p;

        curr = tail = &head;
        p = head.slot;
        head.prev = head.next = NULL;
        *p++ = data;
        while( p!=head.slot ){
            if( p == curr->slot ){
                curr = curr->prev;
                p = curr->slot + JSON2_STACK_CELL_SIZE;
            }
            data = *--p;
            if( SvROK(data) ){
                SV *deref = SvRV(data);
                switch( SvTYPE(deref) ){
                    case SVt_PVAV:
                        {
                            SV **arr = AvARRAY((AV*)deref);
                            I32 i;
                            for(i=av_len((AV*)deref); i>=0; --i){
                                *p++ = arr[i];
                                SHIFT_AND_EXTEND_JSON2_STACK;
                            }
                            continue;
                        }
                    case SVt_PVHV:
                        {
                            HE *entry;
                            hv_iterinit((HV*)deref);
                            while( entry = hv_iternext((HV*)deref) ){
                                *p++ = HeVAL(entry);
                                SHIFT_AND_EXTEND_JSON2_STACK;
                            }
                            continue;
                        }
                }
            }
            if( SvPOK(data) )
                SvUTF8_off(data);
        }
        while( tail!=&head ){
            curr = tail->prev;
            safefree(tail);
            tail = curr;
        }

void
decode_utf8(SV *data)
    CODE:
        struct StackCell_t head, *tail, *curr;
        SV ** p;

        curr = tail = &head;
        p = head.slot;
        head.prev = head.next = NULL;
        *p++ = data;
        while( p!=head.slot ){
            if( p == curr->slot ){
                curr = curr->prev;
                p = curr->slot + JSON2_STACK_CELL_SIZE;
            }
            data = *--p;
            if( SvROK(data) ){
                SV *deref = SvRV(data);
                switch( SvTYPE(deref) ){
                    case SVt_PVAV:
                        {
                            SV **arr = AvARRAY((AV*)deref);
                            I32 i;
                            for(i=av_len((AV*)deref); i>=0; --i){
                                *p++ = arr[i];
                                SHIFT_AND_EXTEND_JSON2_STACK;
                            }
                            continue;
                        }
                    case SVt_PVHV:
                        {
                            HE *entry;
                            hv_iterinit((HV*)deref);
                            while( entry = hv_iternext((HV*)deref) ){
                                *p++ = HeVAL(entry);
                                SHIFT_AND_EXTEND_JSON2_STACK;
                            }
                            continue;
                        }
                }
            }
            if( SvPOK(data) )
                SvUTF8_on(data);
            else if( SvOK(data) )
                SvPVutf8_nolen(data);
        }
        while( tail!=&head ){
            curr = tail->prev;
            safefree(tail);
            tail = curr;
        }
