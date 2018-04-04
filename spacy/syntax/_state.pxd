# cython: infer_types=True
from libc.string cimport memcpy, memset, memmove
from libc.stdlib cimport malloc, calloc, free, realloc
from libc.stdint cimport uint32_t, uint64_t

from cpython.exc cimport PyErr_CheckSignals, PyErr_SetFromErrno

from murmurhash.mrmr cimport hash64

from ..vocab cimport EMPTY_LEXEME
from ..structs cimport TokenC, Entity
from ..lexeme cimport Lexeme
from ..symbols cimport punct
from ..attrs cimport IS_SPACE
from ..typedefs cimport attr_t

include "compile_time.pxi"

cdef inline bint is_space_token(const TokenC* token) nogil:
    return Lexeme.c_check_flag(token.lex, IS_SPACE)

cdef struct RingBufferC:
    int[8] data
    int i
    int default

cdef inline int ring_push(RingBufferC* ring, int value) nogil:
    ring.data[ring.i] = value
    ring.i += 1
    if ring.i >= 8:
        ring.i = 0

cdef inline int ring_get(RingBufferC* ring, int i) nogil:
    if i >= ring.i:
        return ring.default
    else:
        return ring.data[ring.i-i]


cdef cppclass StateC:
    int* _stack
    int* _buffer
    int* was_split
    bint* shifted
    TokenC* _sent
    Entity* _ents
    TokenC _empty_token
    RingBufferC _hist
    int buffer_length
    int max_split
    int length
    int offset
    int _s_i
    int _b_i
    int _e_i
    int _n_until_break

    __init__(const TokenC* sent, int length) nogil:
        cdef int PADDING = 5
        cdef int length_with_split = length * MAX_SPLIT
        this._buffer = <int*>calloc(length_with_split + (PADDING * 2), sizeof(int))
        this._stack = <int*>calloc(length_with_split + (PADDING * 2), sizeof(int))
        this.was_split = <int*>calloc(length_with_split + (PADDING * 2), sizeof(int))
        this.shifted = <bint*>calloc(length_with_split + (PADDING * 2), sizeof(bint))
        this._sent = <TokenC*>calloc(length_with_split + (PADDING * 2), sizeof(TokenC))
        this._ents = <Entity*>calloc(length_with_split + (PADDING * 2), sizeof(Entity))
        if not (this._buffer and this._stack and this.shifted
                and this._sent and this._ents):
            with gil:
                PyErr_SetFromErrno(MemoryError)
                PyErr_CheckSignals()
        memset(&this._hist, 0, sizeof(this._hist))
        this.offset = 0
        cdef int i
        for i in range(length_with_split + (PADDING * 2)):
            this._ents[i].end = -1
            this._sent[i].l_edge = i
            this._sent[i].r_edge = i
        for i in range(PADDING):
            this._sent[i].lex = &EMPTY_LEXEME
        this._sent += PADDING
        this._ents += PADDING
        this._buffer += PADDING
        this._stack += PADDING
        this.shifted += PADDING
        this.was_split += PADDING
        this.length = length
        this.buffer_length = length
        this.max_split = MAX_SPLIT
        this._n_until_break = -1
        this._s_i = 0
        this._b_i = 0
        this._e_i = 0
        for i in range(length):
            this._buffer[i] = i
        memset(&this._empty_token, 0, sizeof(TokenC))
        this._empty_token.lex = &EMPTY_LEXEME
        for i in range(length):
            this._sent[i] = sent[i]
            this._buffer[i] = i
            for j in range(1, MAX_SPLIT):
                this._sent[j*length +i] = sent[i]
        for i in range(length, length+PADDING):
            this._sent[i].lex = &EMPTY_LEXEME

    __dealloc__():
        cdef int PADDING = 5
        free(this._sent - PADDING)
        free(this._ents - PADDING)
        free(this._buffer - PADDING)
        free(this._stack - PADDING)
        free(this.shifted - PADDING)
        free(this.was_split - PADDING)

    void set_context_tokens(int* ids, int n) nogil:
        if n == 2:
            ids[0] = this.B(0) % this.length
            ids[1] = this.S(0) % this.length
        if n == 8:
            ids[0] = this.B(0) % this.length
            ids[1] = this.B(1) % this.length
            ids[2] = this.S(0) % this.length
            ids[3] = this.S(1) % this.length
            ids[4] = this.S(2) % this.length
            ids[5] = this.L(this.B(0), 1) % this.length
            ids[6] = this.L(this.S(0), 1) % this.length
            ids[7] = this.R(this.S(0), 1) % this.length
        elif n == 13:
            ids[0] = this.B(0) % this.length
            ids[1] = this.B(1) % this.length
            ids[2] = this.S(0) % this.length
            ids[3] = this.S(1) % this.length
            ids[4] = this.S(2) % this.length
            ids[5] = this.L(this.S(0), 1) % this.length
            ids[6] = this.L(this.S(0), 2) % this.length
            ids[6] = this.R(this.S(0), 1) % this.length
            ids[7] = this.L(this.B(0), 1) % this.length
            ids[8] = this.R(this.S(0), 2) % this.length
            ids[9] = this.L(this.S(1), 1) % this.length
            ids[10] = this.L(this.S(1), 2) % this.length
            ids[11] = this.R(this.S(1), 1) % this.length
            ids[12] = this.R(this.S(1), 2) % this.length
        elif n == 6:
            if this.B(0) >= 0:
                ids[0] = this.B(0) % this.length
                ids[1] = (this.B(0)-1) % this.length
            else:
                ids[0] = -1
                ids[1] = -1
            ids[2] = this.B(1) % this.length
            ids[3] = this.E(0) % this.length
            if ids[3] >= 1:
                ids[4] = (this.E(0)-1) % this.length
            else:
                ids[4] = -1
            if (ids[3]+1) < this.length:
                ids[5] = (this.E(0)+1) % this.length
            else:
                ids[5] = -1
        else:
            # TODO error =/
            pass
        for i in range(n):
            if ids[i] >= 0:
                ids[i] += this.offset
            else:
                ids[i] = -1

    int can_push() nogil const:
        if this.buffer_length == 0:
            return 0
        else:
            return 1

    int can_pop() nogil const:
        if this.stack_depth() < 1:
            return 0
        else:
            return 1

    int can_arc() nogil const:
        if this.at_break():
            return 0
        elif this.stack_depth() < 1:
            return 0
        elif this.buffer_length == 0:
            return 0
        else:
            return 1

    int can_break() nogil const:
        if this.buffer_length == 0:
            return False
        elif this.B_(0).l_edge < 0:
            return False
        elif this._sent[this.B_(0).l_edge].sent_start < 0:
            return False
        # We only want to break when the 'root' word is on the stack, so that
        # we can add the label.
        elif this.stack_depth() != 1: 
            return False
        elif this.at_break():
            return False
        else:
            return True
    
    int can_split() nogil const:
        if this.max_split < 2:
            return 0
        elif this.buffer_length == 0:
            return 0
        elif this.was_split[this.B(0)]:
            return 0
        else:
            return 1

    int S(int i) nogil const:
        if i >= this._s_i:
            return -1
        return this._stack[this._s_i - (i+1)]

    int B(int i) nogil const:
        if i >= this.buffer_length:
            return -1
        if this._n_until_break != -1 and i >= this._n_until_break:
            return -1
        return this._buffer[this._b_i + i]

    const TokenC* S_(int i) nogil const:
        return this.safe_get(this.S(i))

    const TokenC* B_(int i) nogil const:
        return this.safe_get(this.B(i))

    const TokenC* H_(int i) nogil const:
        return this.safe_get(this.H(i))

    const TokenC* E_(int i) nogil const:
        return this.safe_get(this.E(i))

    const TokenC* L_(int i, int idx) nogil const:
        return this.safe_get(this.L(i, idx))

    const TokenC* R_(int i, int idx) nogil const:
        return this.safe_get(this.R(i, idx))

    const TokenC* safe_get(int i) nogil const:
        if i < 0 or i >= this.length:
            return &this._empty_token
        else:
            return &this._sent[i]

    int H(int i) nogil const:
        if i < 0 or i >= this.length:
            return -1
        return this._sent[i].head + i

    int E(int i) nogil const:
        if this._e_i <= 0 or this._e_i >= this.length:
            return -1
        if i < 0 or i >= this._e_i:
            return -1
        return this._ents[this._e_i - (i+1)].start

    int L(int i, int idx) nogil const:
        if idx < 1:
            return -1
        if i < 0 or i >= this.length:
            return -1
        cdef const TokenC* target = &this._sent[i]
        if target.l_kids < <uint32_t>idx:
            return -1
        cdef const TokenC* ptr = &this._sent[target.l_edge]

        while ptr < target:
            # If this head is still to the right of us, we can skip to it
            # No token that's between this token and this head could be our
            # child.
            if (ptr.head >= 1) and (ptr + ptr.head) < target:
                ptr += ptr.head

            elif ptr + ptr.head == target:
                idx -= 1
                if idx == 0:
                    return ptr - this._sent
                ptr += 1
            else:
                ptr += 1
        return -1

    int R(int i, int idx) nogil const:
        if idx < 1:
            return -1
        if i < 0 or i >= this.length:
            return -1
        cdef const TokenC* target = &this._sent[i]
        if target.r_kids < <uint32_t>idx:
            return -1
        cdef const TokenC* ptr = &this._sent[target.r_edge]
        while ptr > target:
            # If this head is still to the right of us, we can skip to it
            # No token that's between this token and this head could be our
            # child.
            if (ptr.head < 0) and ((ptr + ptr.head) > target):
                ptr += ptr.head
            elif ptr + ptr.head == target:
                idx -= 1
                if idx == 0:
                    return ptr - this._sent
                ptr -= 1
            else:
                ptr -= 1
        return -1

    bint empty() nogil const:
        return this._s_i <= 0

    bint eol() nogil const:
        return this.buffer_length == 0 or this.at_break()

    bint at_break() nogil const:
        return this._n_until_break == 0

    bint is_final() nogil const:
        return this.stack_depth() <= 1 and this.buffer_length == 0

    bint has_head(int i) nogil const:
        return this.safe_get(i).head != 0

    int n_L(int i) nogil const:
        return this.safe_get(i).l_kids

    int n_R(int i) nogil const:
        return this.safe_get(i).r_kids

    bint stack_is_connected() nogil const:
        return False

    bint entity_is_open() nogil const:
        if this._e_i < 1:
            return False
        return this._ents[this._e_i-1].end == -1

    int stack_depth() nogil const:
        return this._s_i

    int segment_length() nogil const:
        if this._n_until_break != -1:
            return this._n_until_break
        else:
            return this.buffer_length

    uint64_t hash() nogil const:
        cdef TokenC[11] sig
        sig[0] = this.S_(2)[0]
        sig[1] = this.S_(1)[0]
        sig[2] = this.R_(this.S(1), 1)[0]
        sig[3] = this.L_(this.S(0), 1)[0]
        sig[4] = this.L_(this.S(0), 2)[0]
        sig[5] = this.S_(0)[0]
        sig[6] = this.R_(this.S(0), 2)[0]
        sig[7] = this.R_(this.S(0), 1)[0]
        sig[8] = this.B_(0)[0]
        sig[9] = this.E_(0)[0]
        sig[10] = this.E_(1)[0]
        return hash64(sig, sizeof(sig), this._s_i) \
             + hash64(<void*>&this._hist, sizeof(RingBufferC), 1)

    void push_hist(int act) nogil:
        ring_push(&this._hist, act+1)

    int get_hist(int i) nogil:
        return ring_get(&this._hist, i)

    void push() nogil:
        if this.buffer_length != 0:
            this._stack[this._s_i] = this._buffer[this._b_i]
        if this._n_until_break != -1:
            this._n_until_break -= 1
        this._s_i += 1
        this._b_i += 1
        this.buffer_length -= 1
        if this.B_(0).sent_start == 1:
            this.set_break(0)

    void split(int i, int n) nogil:
        '''Split token i of the buffer into N pieces.'''
        # Let's say we've got a length 10 sentence. 4 is start of buffer.
        # We do: state.split(1, 2)
        #
        # Old buffer: 4,5,6,7,8,9
        # New buffer: 4,5,13,22,6,7,8,9
        if (this._b_i+5*2) < n:
            with gil:
                raise NotImplementedError
        # Let's say we're at token index 4. this._b_i will be 4, so that we
        # point forward into the buffer. To insert, we don't need to reallocate
        # -- we have space at the start; we can just shift the tokens between
        # where we are at the buffer and where the split starts backwards to
        # make room.
        #
        # For b_i=4, i=1, n=2 we want to have:
        # Old buffer: [_, _, _, _, 4,  5,  6, 7, 8, 9]   and  b_i=4
        # New buffer: [_, _, 4, 5, 13, 22, 6, 7, 8, 9] and  b_i=2
        # b_i will always move back by n in total, as that's
        # the size of the gap we're creating.
        # The number of values we have to copy will be i+1
        # Another way to see it:
        # For b_i=4, i=1, n=2
        # buffer[2:4] = buffer[4:6]
        # buffer[4:6] = new_tokens
        # For b_i=7, i=1, n=1
        # buffer[6:8] = buffer[7:9]
        # buffer[8:9] = new_tokens
        # For b_i=3, i=1, n=3
        # buffer[0:2] = buffer[3:5]
        # buffer[2:5] = new_tokens
        # For b_i=5, i=3, n=1
        # buffer[4:8] = buffer[5:9]
        # buffer[8:9] = new_tokens
        cdef int target = this.B(i)
        this._b_i -= n
        memmove(&this._buffer[this._b_i],
            &this._buffer[this._b_i+n], (i+1)*sizeof(this._buffer[0]))
        cdef int subtoken, new_token
        for subtoken in range(n):
            new_token = (subtoken+1) * this.length + target
            this._buffer[this._b_i+(i+1)+subtoken] = new_token
        this.buffer_length += n
        if this._n_until_break != -1:
            this._n_until_break += n
        for i in range(n+1):
            this.was_split[this.B(i)] = n

    void pop() nogil:
        if this._s_i >= 1:
            this._s_i -= 1

    void unshift() nogil:
        this._b_i -= 1
        this._buffer[this._b_i] = this.S(0)
        this._s_i -= 1
        this.shifted[this.B(0)] = True
        this.buffer_length += 1
        if this._n_until_break != -1:
            this._n_until_break += 1

    void add_arc(int head, int child, attr_t label) nogil:
        if this.has_head(child):
            this.del_arc(this.H(child), child)

        cdef int dist = head - child
        this._sent[child].head = dist
        this._sent[child].dep = label
        cdef int i
        if child > head:
            this._sent[head].r_kids += 1
            # Some transition systems can have a word in the buffer have a
            # rightward child, e.g. from Unshift.
            this._sent[head].r_edge = this._sent[child].r_edge
            i = 0
            while this.has_head(head) and i < this.length:
                head = this.H(head)
                this._sent[head].r_edge = this._sent[child].r_edge
                i += 1 # Guard against infinite loops
        else:
            this._sent[head].l_kids += 1
            this._sent[head].l_edge = this._sent[child].l_edge

    void del_arc(int h_i, int c_i) nogil:
        cdef int dist = h_i - c_i
        cdef TokenC* h = &this._sent[h_i]
        cdef int i = 0
        if c_i > h_i:
            # this.R_(h_i, 2) returns the second-rightmost child token of h_i
            # If we have more than 2 rightmost children, our 2nd rightmost child's
            # rightmost edge is going to be our new rightmost edge.
            h.r_edge = this.R_(h_i, 2).r_edge if h.r_kids >= 2 else h_i
            h.r_kids -= 1
            new_edge = h.r_edge
            # Correct upwards in the tree --- see Issue #251
            while h.head < 0 and i < this.length: # Guard infinite loop
                h += h.head
                h.r_edge = new_edge
                i += 1
        else:
            # Same logic applies for left edge, but we don't need to walk up
            # the tree, as the head is off the stack.
            h.l_edge = this.L_(h_i, 2).l_edge if h.l_kids >= 2 else h_i
            h.l_kids -= 1

    void open_ent(attr_t label) nogil:
        this._ents[this._e_i].start = this.B(0)
        this._ents[this._e_i].label = label
        this._ents[this._e_i].end = -1
        this._e_i += 1

    void close_ent() nogil:
        # Note that we don't decrement _e_i here! We want to maintain all
        # entities, not over-write them...
        this._ents[this._e_i-1].end = this.B(0)+1
        this._sent[this.B(0)].ent_iob = 1

    void set_ent_tag(int i, int ent_iob, attr_t ent_type) nogil:
        if 0 <= i < this.length:
            this._sent[i].ent_iob = ent_iob
            this._sent[i].ent_type = ent_type

    void set_break(int i) nogil:
        if 0 <= i < this.buffer_length:
            this._sent[this.B_(i).l_edge].sent_start = 1
            this._n_until_break = i

    void clone(const StateC* src) nogil:
        this.length = src.length
        cdef int length_with_split = this.length * this.max_split
        this.buffer_length = src.buffer_length
        memcpy(this._sent, src._sent, length_with_split * sizeof(TokenC))
        memcpy(this._stack, src._stack, length_with_split * sizeof(int))
        memcpy(this._buffer, src._buffer, length_with_split * sizeof(int))
        memcpy(this._ents, src._ents, length_with_split * sizeof(Entity))
        memcpy(this.shifted, src.shifted, length_with_split * sizeof(this.shifted[0]))
        memcpy(this.was_split, src.was_split, length_with_split * sizeof(this.was_split[0]))
        this._b_i = src._b_i
        this._s_i = src._s_i
        this._e_i = src._e_i
        this._n_until_break = src._n_until_break
        this.offset = src.offset
        this._empty_token = src._empty_token
