module c3voxel::platform;

struct MouseState {
    double x;
    double y;
    double dx;
    double dy;
    bool   left_down;
    int    scroll_steps;
}

fn void input_poll(MouseState* out, Window* win)
{
    *out = win.mouse;
    win.mouse.dx           = 0.0;
    win.mouse.dy           = 0.0;
    win.mouse.scroll_steps = 0;
}
