module c3voxel::gpu;

import std::io;

import opengl::gl;

const int MAX_TIMER_NODES = 256;
const int MAX_TIMER_DEPTH = 8;
const int TIMER_FRAMES    = 2;          // double-buffered to avoid stalling on resolve

alias NodeIndex  = int;
alias FrameIndex = int;
const NodeIndex NODE_NONE = -1;

struct TimerNode {
    String    label;
    NodeIndex parent;
    NodeIndex first_child;
    NodeIndex next_sibling;
    double    gpu_ms;                    // filled by resolve_prev
}

struct TimerFrame {
    TimerNode[MAX_TIMER_NODES] nodes;
    int                         node_count;
    int                         root;     // first top-level node index, NODE_NONE if empty
}

struct Timer {
    TimerFrame[TIMER_FRAMES]                   frames;
    uint[TIMER_FRAMES * MAX_TIMER_NODES * 2]   query_pool;   // [start, end] pairs per node per frame slot
    NodeIndex[MAX_TIMER_DEPTH]                 stack;
    int                                         stack_top;    // -1 = empty
    FrameIndex                                  frame_index;
    bool                                        overflow_warned;
    bool                                        initialized;
}

fn void Timer.init(&self)
{
    if (self.initialized) return;
    gl::genQueries((int)self.query_pool.len, &self.query_pool[0]);
    self.stack_top = -1;
    self.frame_index = 0;
    self.overflow_warned = false;
    for (int f = 0; f < TIMER_FRAMES; f++) {
        self.frames[f].node_count = 0;
        self.frames[f].root       = NODE_NONE;
    }
    self.initialized = true;
}

fn void Timer.destroy(&self)
{
    if (!self.initialized) return;
    gl::deleteQueries((int)self.query_pool.len, &self.query_pool[0]);
    self.initialized = false;
}

fn void Timer.begin_frame(&self)
{
    int slot = (int)(self.frame_index % (FrameIndex)TIMER_FRAMES);
    self.frames[slot].node_count = 0;
    self.frames[slot].root       = NODE_NONE;
    self.stack_top = -1;
}

fn void Timer.end_frame(&self)
{
    if (self.stack_top != -1) {
        io::eprintfn("[timer] unbalanced push/pop at frame end (stack_top=%d)", self.stack_top);
        self.stack_top = -1;
    }
    self.frame_index++;
}

fn void Timer.resolve_prev(&self)
{
    if (self.frame_index == 0) return;   // nothing to read yet
    int prev_slot = (int)((self.frame_index - 1) % (FrameIndex)TIMER_FRAMES);
    TimerFrame* frame = &self.frames[prev_slot];
    int pool_base = prev_slot * MAX_TIMER_NODES * 2;
    for (int i = 0; i < frame.node_count; i++) {
        GLuint64 t_start = 0;
        GLuint64 t_end   = 0;
        gl::getQueryObjectui64v(self.query_pool[pool_base + i * 2 + 0], (GLenum)gl::GL_QUERY_RESULT, &t_start);
        gl::getQueryObjectui64v(self.query_pool[pool_base + i * 2 + 1], (GLenum)gl::GL_QUERY_RESULT, &t_end);
        frame.nodes[i].gpu_ms = (double)(t_end - t_start) / 1_000_000.0;
    }
}

fn TimerNode* Timer.prev_root(&self)
{
    if (self.frame_index == 0) return null;
    int prev_slot = (int)((self.frame_index - 1) % (FrameIndex)TIMER_FRAMES);
    TimerFrame* frame = &self.frames[prev_slot];
    if (frame.root == NODE_NONE) return null;
    return &frame.nodes[frame.root];
}

fn TimerFrame* Timer.prev_frame(&self)
{
    if (self.frame_index == 0) return null;
    int prev_slot = (int)((self.frame_index - 1) % (FrameIndex)TIMER_FRAMES);
    return &self.frames[prev_slot];
}

fn void Timer.dump(&self)
{
    TimerFrame* frame = self.prev_frame();
    if (frame == null || frame.root == NODE_NONE) {
        io::printfn("[timer] no data yet");
        return;
    }
    io::printfn("[timer] frame %d", self.frame_index - 1);
    NodeIndex idx = frame.root;
    while (idx != NODE_NONE) {
        dump_subtree(frame, idx, 0);
        idx = frame.nodes[idx].next_sibling;
    }
}

fn void dump_subtree(TimerFrame* frame, NodeIndex idx, int depth) @local
{
    TimerNode* n = &frame.nodes[idx];
    for (int i = 0; i < depth; i++) io::print("  ");
    io::printfn("%s: %.3f ms", n.label, n.gpu_ms);
    NodeIndex child = n.first_child;
    while (child != NODE_NONE) {
        dump_subtree(frame, child, depth + 1);
        child = frame.nodes[child].next_sibling;
    }
}

fn void Commands.time_push(&self, String label)
{
    Timer* t = self.timer;
    if (t == null || !t.initialized) return;

    int slot = (int)(t.frame_index % (FrameIndex)TIMER_FRAMES);
    TimerFrame* frame = &t.frames[slot];

    if (frame.node_count >= MAX_TIMER_NODES || t.stack_top >= MAX_TIMER_DEPTH - 1) {
        if (!t.overflow_warned) {
            io::eprintfn("[timer] overflow (nodes=%d depth=%d) — dropping push %s",
                         frame.node_count, t.stack_top + 1, label);
            t.overflow_warned = true;
        }
        return;
    }

    NodeIndex idx = (NodeIndex)frame.node_count++;
    NodeIndex parent = t.stack_top >= 0 ? t.stack[t.stack_top] : NODE_NONE;

    TimerNode* n = &frame.nodes[idx];
    n.label        = label;
    n.parent       = parent;
    n.first_child  = NODE_NONE;
    n.next_sibling = NODE_NONE;
    n.gpu_ms       = 0.0;

    // link into parent's child list or the frame root chain
    if (parent == NODE_NONE) {
        if (frame.root == NODE_NONE) {
            frame.root = idx;
        } else {
            NodeIndex tail = frame.root;
            while (frame.nodes[tail].next_sibling != NODE_NONE) tail = frame.nodes[tail].next_sibling;
            frame.nodes[tail].next_sibling = idx;
        }
    } else {
        TimerNode* p = &frame.nodes[parent];
        if (p.first_child == NODE_NONE) {
            p.first_child = idx;
        } else {
            NodeIndex tail = p.first_child;
            while (frame.nodes[tail].next_sibling != NODE_NONE) tail = frame.nodes[tail].next_sibling;
            frame.nodes[tail].next_sibling = idx;
        }
    }

    int pool_base = slot * MAX_TIMER_NODES * 2;
    gl::queryCounter(t.query_pool[pool_base + idx * 2 + 0], (GLenum)gl::GL_TIMESTAMP);

    t.stack[++t.stack_top] = idx;
}

fn void Commands.time_pop(&self)
{
    Timer* t = self.timer;
    if (t == null || !t.initialized) return;
    if (t.stack_top < 0) {
        io::eprintfn("[timer] time_pop with empty stack");
        return;
    }

    int slot = (int)(t.frame_index % (FrameIndex)TIMER_FRAMES);
    NodeIndex idx = t.stack[t.stack_top--];
    int pool_base = slot * MAX_TIMER_NODES * 2;
    gl::queryCounter(t.query_pool[pool_base + idx * 2 + 1], (GLenum)gl::GL_TIMESTAMP);
}
