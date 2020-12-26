const sg = @import("sokol").gfx;
const sapp = @import("sokol").app;
const stm = @import("sokol").time;
const sgapp = @import("sokol").app_gfx_glue;
const assert = @import("std").debug.assert;

const warn = @import("std").debug.warn;

// debugging options
const DbgSkipIntro = false;         // set to true to skip intro gamestate
const DbgSkipPrelude = false;       // set to true to skip prelude at start of gameloop
const DbgStartRound = 0;            // set to any starting round <= 255
const DbgShowMarkers = false;       // set to true to display debug markers
const DbgEscape = true;            // set to true to end game round with Escape
const DbgDoubleSpeed = false;       // set to true to speed up game
const DbgGodMode = false;           // set to true to make Pacman invulnerable

// various constants
const TickDurationNS = if (DbgDoubleSpeed) 8_333_33 else 16_666_667;
const MaxFrameTimeNS = 33_333_333.0;    // max duration of a frame in nanoseconds
const TickToleranceNS = 1_000_000;      // max time tolerance of a game tick in nanoseconds
const FadeTicks = 30;                   // fade in/out duration in game ticks
const NumDebugMarkers = 16;

// common tile codes
const TileCodeSpace      = 0x40;
const TileCodeDot        = 0x10;
const TileCodePill       = 0x14;
const TileCodeGhost      = 0xB0;
const TileCodeLife       = 0x20; // 0x20..0x23
const TileCodeCherries   = 0x90; // 0x90..0x93
const TileCodeStrawberry = 0x94; // 0x94..0x97
const TileCodePeach      = 0x98; // 0x98..0x9B
const TileCodeBell       = 0x9C; // 0x9C..0x9F
const TileCodeApple      = 0xA0; // 0xA0..0xA3
const TileCodeGrapes     = 0xA4; // 0xA4..0xA7
const TileCodeGalaxian   = 0xA8; // 0xA8..0xAB
const TileCodeKey        = 0xAC; // 0xAC..0xAF
const TileCodeDoor       = 0xCF; // the ghost-house door

// common sprite tile codes
const SpriteCodeInvisible    = 30;
const SpriteCodeScore200     = 40;
const SpriteCodeScore400     = 41;
const SpriteCodeScore800     = 42;
const SpriteCodeScore1600    = 43;
const SpriteCodeCherries     = 0;
const SpriteCodeStrawberry   = 1;
const SpriteCodePeach        = 2;
const SpriteCodeBell         = 3;
const SpriteCodeApple        = 4;
const SpriteCodeGrapes       = 5;
const SpriteCodeGalaxian     = 6;
const SpriteCodeKey          = 7;
const SpriteCodePacmanClosedMouth = 48;

// common color codes
const ColorCodeBlank         = 0x00;
const ColorCodeDefault       = 0x0F;
const ColorCodeDot           = 0x10;
const ColorCodePacman        = 0x09;
const ColorCodeBlinky        = 0x01;
const ColorCodePinky         = 0x03;
const ColorCodeInky          = 0x05;
const ColorCodeClyde         = 0x07;
const ColorCodeFrightened    = 0x11;
const ColorCodeFrightenedBlinking = 0x12;
const ColorCodeGhostScore    = 0x18;
const ColorCodeEyes          = 0x19;
const ColorCodeCherries      = 0x14;
const ColorCodeStrawberry    = 0x0F;
const ColorCodePeach         = 0x15;
const ColorCodeBell          = 0x16;
const ColorCodeApple         = 0x14;
const ColorCodeGrapes        = 0x17;
const ColorCodeGalaxian      = 0x09;
const ColorCodeKey           = 0x16;
const ColorCodeWhiteBorder   = 0x1F;
const ColorCodeFruitScore    = 0x03;

// all mutable state is in a single nested global
const State = struct {
    timing: struct {
        tick: u32 = 0,
        laptime_store: u64 = 0,
        tick_accum: i32 = 0,
    } = .{},
    gamestate: GameState = undefined,
    input: Input = .{},
    intro: Intro = .{},
    game: Game = .{},
    gfx: Gfx = .{},
};
var state: State = .{};

//--- helper structs and functions ---------------------------------------------
const ivec2 = @Vector(2,i16);

fn validTilePos(pos: ivec2) bool {
    return (pos[0] >= 0) and (pos[0] < DisplayTilesX) and (pos[1] >= 0) and (pos[1] < DisplayTilesY);
}

//--- gameplay system ----------------------------------------------------------
const GameState = enum {
    Intro,
    Game,
};

const Dir = enum {
    Right,
    Down,
    Left,
    Up,

    // return reveres direction
    fn reverse(self: Dir) Dir {
        return switch (self) {
            .Right => .Left,
            .Down  => .Up,
            .Left  => .Right,
            .Up    => .Down,
        };
    }

    // return a vector for a given direction
    fn vec(dir: Dir) ivec2 {
        return switch (dir) {
            .Right => .{ 1, 0 },
            .Down  => .{ 0, 1 },
            .Left  => .{ -1, 0 },
            .Up    => .{ 0, -1 }
        };
    }
};

// bonus fruit types
const Fruit = enum {
    None,
    Cherries,
    Strawberry,
    Peach,
    Apple,
    Grapes,
    Galaxian,
    Bell,
    Key,

    // as background tile code...
    fn tile(fruit: Fruit) u8 {
        return switch (fruit) {
            .None       => TileCodeSpace,
            .Cherries   => TileCodeCherries,
            .Strawberry => TileCodeStrawberry,
            .Peach      => TileCodePeach,
            .Apple      => TileCodeApple,
            .Grapes     => TileCodeGrapes,
            .Galaxian   => TileCodeGalaxian,
            .Bell       => TileCodeBell,
            .Key        => TileCodeKey,
        };
    }

    // as color code...
    fn color(fruit: Fruit) u8 {
        return switch (fruit) {
            .None       => ColorCodeBlank,
            .Cherries   => ColorCodeCherries,
            .Strawberry => ColorCodeStrawberry,
            .Peach      => ColorCodePeach,
            .Apple      => ColorCodeApple,
            .Grapes     => ColorCodeGrapes,
            .Galaxian   => ColorCodeGalaxian,
            .Bell       => ColorCodeBell,
            .Key        => ColorCodeKey,
        };
    }

    // as sprite tile code
    fn sprite(fruit: Fruit) u8 {
        return switch (fruit) {
            .None       => SpriteCodeInvisible,
            .Cherries   => SpriteCodeCherries,
            .Strawberry => SpriteCodeStrawberry,
            .Peach      => SpriteCodePeach,
            .Apple      => SpriteCodeApple,
            .Grapes     => SpriteCodeGrapes,
            .Galaxian   => SpriteCodeGalaxian,
            .Bell       => SpriteCodeBell,
            .Key        => SpriteCodeKey,
        };
    }
};

//--- Game gamestate -----------------------------------------------------------

// gameplay constants
const NumLives = 3;
const NumDots = 244;
const NumPills = 4;
const AntePortasX = 14*TileWidth;   // x/y position of ghost hour entry
const AntePortasY = 14*TileHeight + TileHeight/2;
const FruitActiveTicks = 10 * 60;   // number of ticks the bonus fruit is shown
const GhostEatenFreezeTicks = 60;   // number of ticks the game freezes after Pacman eats a ghost
const PacmanEatenTicks = 60;        // number of ticks the game freezes after Pacman gets eaten
const PacmanDeathTicks = 150;       // number of ticks to show the Pacman death sequence before starting a new round
const GameOverTicks = 3*60;         // number of ticks to show the Game Over message
const RoundWonTicks = 4*60;         // number of ticks to wait after a round was won

// flags for Game.freeze
const FreezePrelude:    u8 = (1<<0);
const FreezeReady:      u8 = (1<<1);
const FreezeEatGhost:   u8 = (1<<2);
const FreezeDead:       u8 = (1<<3);
const FreezeWon:        u8 = (1<<4);

const Game = struct {

    xorshift:           u32 = 0x12345678,   // xorshift random-number-generator state
    score:              u32 = 0,
    hiscore:            u32 = 0,
    num_lives:          u8 = 0,
    round:              u8 = 0,
    freeze:             u8 = 0,             // combination of Freeze* flags
    num_dots_eaten:     u8 = 0,
    num_ghosts_eaten:   u8 = 0,
    active_fruit:       Fruit = .None,
    
    global_dot_counter_active: bool = false,
    global_dot_counter: u16 = 0,

    started:            Trigger = .{},
    prelude_started:    Trigger = .{},
    ready_started:      Trigger = .{},
    round_started:      Trigger = .{},
    round_won:          Trigger = .{},
    game_over:          Trigger = .{},
    dot_eaten:          Trigger = .{},
    pill_eaten:         Trigger = .{},
    ghost_eaten:        Trigger = .{},
    pacman_eaten:       Trigger = .{},
    fruit_eaten:        Trigger = .{},
    force_leave_house:  Trigger = .{},
    fruit_active:       Trigger = .{},
};

// level specifications
const LevelSpec = struct {
    bonus_fruit: Fruit,
    bonus_score: u32,
    fright_ticks: u32,
};
const MaxLevelSpec = 21;
const LevelSpecTable = [MaxLevelSpec]LevelSpec {
    .{ .bonus_fruit=.Cherries,   .bonus_score = 10, .fright_ticks = 6*60 },
    .{ .bonus_fruit=.Strawberry, .bonus_score=30,  .fright_ticks=5*60, },
    .{ .bonus_fruit=.Peach,      .bonus_score=50,  .fright_ticks=4*60, },
    .{ .bonus_fruit=.Peach,      .bonus_score=50,  .fright_ticks=3*60, },
    .{ .bonus_fruit=.Apple,      .bonus_score=70,  .fright_ticks=2*60, },
    .{ .bonus_fruit=.Apple,      .bonus_score=70,  .fright_ticks=5*60, },
    .{ .bonus_fruit=.Grapes,     .bonus_score=100, .fright_ticks=2*60, },
    .{ .bonus_fruit=.Grapes,     .bonus_score=100, .fright_ticks=2*60, },
    .{ .bonus_fruit=.Galaxian,   .bonus_score=200, .fright_ticks=1*60, },
    .{ .bonus_fruit=.Galaxian,   .bonus_score=200, .fright_ticks=5*60, },
    .{ .bonus_fruit=.Bell,       .bonus_score=300, .fright_ticks=2*60, },
    .{ .bonus_fruit=.Bell,       .bonus_score=300, .fright_ticks=1*60, },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1*60, },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=3*60, },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1*60, },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1*60, },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1,    },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1*60, },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1,    },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1,    },
    .{ .bonus_fruit=.Key,        .bonus_score=500, .fright_ticks=1,    },
};

// get level spec for the current game round
fn gameLevelSpec(round: u32) LevelSpec {
    var i = round;
    if (i >= MaxLevelSpec) {
        i = MaxLevelSpec - 1;
    }
    return LevelSpecTable[i];
}

// the central game tick function, called at 60Hz
fn gameTick() void {

    // initialize game-state once
    if (state.game.started.now()) {
        // debug: skip predule
        const prelude_ticks_per_sec = if (DbgSkipPrelude) 1 else 60;
        state.gfx.fadein.start();
        state.game.prelude_started.start();
        state.game.ready_started.startAfter(2*prelude_ticks_per_sec);
        // FIXME: start prelude sound
        gameInit();
    }

    // initialize new round (after eating all dots or losing a life)
    if (state.game.ready_started.now()) {
        gameRoundInit();
        // after 2 seconds, start the interactive game loop
        state.game.round_started.startAfter(2*60 + 10);
    }
    if (state.game.round_started.now()) {
        state.game.freeze &= ~FreezeReady;
        // clear the READY! message
        gfxColorText(.{11,20}, ColorCodeDot, "      ");
        // FIXME: start weeooh sound
    }

    // activate/deactivate bonus fruit
    if (state.game.fruit_active.now()) {
        state.game.active_fruit = gameLevelSpec(state.game.round).bonus_fruit;
    }
    else if (state.game.fruit_active.afterOnce(FruitActiveTicks)) {
        state.game.active_fruit = .None;
    }

    // stop frightened sound and start weeooh sound
    if (state.game.pill_eaten.afterOnce(gameLevelSpec(state.game.round).fright_ticks)) {
        // FIXME: start weeooh sound
    }

    // if game is frozen because Pacman ate a ghost, unfreeze after a while
    if (0 != (state.game.freeze & FreezeEatGhost)) {
        if (state.game.ghost_eaten.afterOnce(GhostEatenFreezeTicks)) {
            state.game.freeze &= ~FreezeEatGhost;
        }
    }

    // play pacman-death sound
    if (state.game.pacman_eaten.afterOnce(PacmanEatenTicks)) {
        // FIXME: play sound
    }

    // update Pacman and ghost state
    if (0 != state.game.freeze) {
        // FIXME!
    }
    gameUpdateTiles();
    //gameUpdateSprites();

    // update hiscore if broken
    if (state.game.score > state.game.hiscore) {
        state.game.hiscore = state.game.score;
    }

    // check for end-round condition
    if (state.game.round_won.now()) {
        state.game.freeze |= FreezeWon;
        state.game.ready_started.startAfter(RoundWonTicks);
    }
    if (state.game.game_over.now()) {
        gfxColorText(.{9,20}, 1, "GAME  OVER");
        state.input.disable();
        state.gfx.fadeout.startAfter(GameOverTicks);
        state.intro.started.startAfter(GameOverTicks + FadeTicks);
    }

    if (DbgEscape) {
        if (state.input.esc) {
            state.input.disable();
            state.gfx.fadeout.start();
            state.intro.started.startAfter(FadeTicks);
        }
    }

    // FIXME: render debug markers
}

// common time trigger initialization at start of a game round
fn gameInitTriggers() void {
    state.game.round_won.disable();
    state.game.game_over.disable();
    state.game.dot_eaten.disable();
    state.game.pill_eaten.disable();
    state.game.ghost_eaten.disable();
    state.game.pacman_eaten.disable();
    state.game.fruit_eaten.disable();
    state.game.force_leave_house.disable();
    state.game.fruit_active.disable();
}

// intialize a new game
fn gameInit() void {
    state.input.enable();
    gameInitTriggers();
    state.game.round = DbgStartRound;
    state.game.freeze = FreezePrelude;
    state.game.num_lives = NumLives;
    state.game.global_dot_counter_active = false;
    state.game.global_dot_counter = 0;
    state.game.num_dots_eaten = 0;
    state.game.score = 0;

    // draw the playfield and PLAYER ONE READY! message
    gfxClear(TileCodeSpace, ColorCodeDot);
    gfxColorText(.{9,0}, ColorCodeDefault, "HIGH SCORE");
    gameInitPlayfield();
    gfxColorText(.{9,14}, 5, "PLAYER ONE");
    gfxColorText(.{11,20}, 9, "READY!");
}

// initialize the playfield background tiles
fn gameInitPlayfield() void {
    gfxClearPlayfieldToColor(ColorCodeDot);
    // decode the playfield data from an ASCII map
    const tiles =
       \\0UUUUUUUUUUUU45UUUUUUUUUUUU1
       \\L............rl............R
       \\L.ebbf.ebbbf.rl.ebbbf.ebbf.R
       \\LPr  l.r   l.rl.r   l.r  lPR
       \\L.guuh.guuuh.gh.guuuh.guuh.R
       \\L..........................R
       \\L.ebbf.ef.ebbbbbbf.ef.ebbf.R
       \\L.guuh.rl.guuyxuuh.rl.guuh.R
       \\L......rl....rl....rl......R
       \\2BBBBf.rzbbf rl ebbwl.eBBBB3
       \\     L.rxuuh gh guuyl.R     
       \\     L.rl          rl.R     
       \\     L.rl mjs--tjn rl.R     
       \\UUUUUh.gh i      q gh.gUUUUU
       \\      .   i      q   .      
       \\BBBBBf.ef i      q ef.eBBBBB
       \\     L.rl okkkkkkp rl.R     
       \\     L.rl          rl.R     
       \\     L.rl ebbbbbbf rl.R     
       \\0UUUUh.gh guuyxuuh gh.gUUUU1
       \\L............rl............R
       \\L.ebbf.ebbbf.rl.ebbbf.ebbf.R
       \\L.guyl.guuuh.gh.guuuh.rxuh.R
       \\LP..rl.......  .......rl..PR
       \\6bf.rl.ef.ebbbbbbf.ef.rl.eb8
       \\7uh.gh.rl.guuyxuuh.rl.gh.gu9
       \\L......rl....rl....rl......R
       \\L.ebbbbwzbbf.rl.ebbwzbbbbf.R
       \\L.guuuuuuuuh.gh.guuuuuuuuh.R
       \\L..........................R
       \\2BBBBBBBBBBBBBBBBBBBBBBBBBB3
       ;
    // map ASCII to tile codes
    var t = [_]u8{TileCodeDot} ** 128;
    t[' ']=0x40; t['0']=0xD1; t['1']=0xD0; t['2']=0xD5; t['3']=0xD4; t['4']=0xFB;
    t['5']=0xFA; t['6']=0xD7; t['7']=0xD9; t['8']=0xD6; t['9']=0xD8; t['U']=0xDB;
    t['L']=0xD3; t['R']=0xD2; t['B']=0xDC; t['b']=0xDF; t['e']=0xE7; t['f']=0xE6;
    t['g']=0xEB; t['h']=0xEA; t['l']=0xE8; t['r']=0xE9; t['u']=0xE5; t['w']=0xF5;
    t['x']=0xF2; t['y']=0xF3; t['z']=0xF4; t['m']=0xED; t['n']=0xEC; t['o']=0xEF;
    t['p']=0xEE; t['j']=0xDD; t['i']=0xD2; t['k']=0xDB; t['q']=0xD3; t['s']=0xF1;
    t['t']=0xF0; t['-']=TileCodeDoor; t['P']=TileCodePill;
    var y: i16 = 3;
    var i: usize = 0;
    while (y < DisplayTilesY-2): (y += 1) {
        var x: i16 = 0;
        while (x < DisplayTilesX): ({ x += 1; i += 1; }) {
            gfxTile(.{x,y}, t[tiles[i] & 127]);
        }
        // skip newline
        i += 1;
    }
}

// initialize a new game round
fn gameRoundInit() void {
    gfxClearSprites();

    // clear the PLAYER ONE text
    gfxColorText(.{9,14}, ColorCodeDot, "          ");

    // if a new round was started because Pacman had won (eaten all dots),
    // redraw the playfield and reset the global dot counter
    if (state.game.num_dots_eaten == NumDots) {
        state.game.round += 1;
        state.game.num_dots_eaten = 0;
        state.game.global_dot_counter_active = false;
        gameInitPlayfield();
    }
    else {
        // if the previous round was lost, use the global dot counter 
        // to detect when ghosts should leave the ghost house instead
        // of the per-ghost dot counter
        if (state.game.num_lives != NumLives) {
            state.game.global_dot_counter_active = true;
            state.game.global_dot_counter = 0;
        }
        state.game.num_lives -= 1;
    }
    assert(state.game.num_lives > 0);

    state.game.active_fruit = .None;
    state.game.freeze = FreezeReady;
    state.game.xorshift = 0x12345678;
    state.game.num_ghosts_eaten = 0;
    gameInitTriggers();

    gfxColorText(.{11,20}, 9, "READY!");

    // the force-house trigger forces ghosts out of the house if Pacman
    // hasn't been eating dots for a while
    state.game.force_leave_house.start();

    // FIXME: init Pacman and Ghost state
}

// update dynamic background tiles
fn gameUpdateTiles() void {
    // print score and hiscore
    gfxColorScore(.{6,1}, ColorCodeDefault, state.game.score);
    if (state.game.hiscore > 0) {
        gfxColorScore(.{16,1}, ColorCodeDefault, state.game.hiscore);
    }

    // update the energizer pill state (blinking/non-blinking)
    const pill_pos = [NumPills]ivec2 { .{1,6}, .{26,6}, .{1,26}, .{26,26} };
    for (pill_pos) |pos| {
        if (0 != state.game.freeze) {
            gfxColor(pos, ColorCodeDot);
        }
        else {
            gfxColor(pos, if (0 != (state.timing.tick & 8)) ColorCodeDot else ColorCodeBlank);
        }
    }

    // clear the fruit-eaten score after Pacman has eaten a bonus fruit
    if (state.game.fruit_eaten.afterOnce(2*60)) {
        // FIXME!
        // gfxFruitScore(.None);
        assert(false);
    }

    // remaining lives in bottom-left corner
    {
        var i: i16 = 0;
        while (i < NumLives): (i += 1) {
            const color: u8 = if (i < state.game.num_lives) ColorCodePacman else ColorCodeBlank;
            gfxColorTileQuad(.{2+2*i,34}, color, TileCodeLife);
        }
    }

    // bonus fruits in bottom-right corner
    {
        var i: i32 = @intCast(i32,state.game.round) - 7 + 1;
        var x: i16 = 24;
        while (i <= state.game.round): (i += 1) {
            if (i >= 0) {
                const fruit = gameLevelSpec(@intCast(u32,i)).bonus_fruit;
                gfxColorTileQuad(.{x,34}, fruit.color(), fruit.tile());
                x -= 2;
            }
        }
    }

    // if game round was won, render the entire playfield as blinking blue/white
    if (state.game.round_won.after(1*60)) {
        if (0 != (state.game.round_won.since() & 0x10)) {
            gfxClearPlayfieldToColor(ColorCodeDot);
        }
        else {
            gfxClearPlayfieldToColor(ColorCodeWhiteBorder);
        }
    }
}

//--- Intro gamestate ----------------------------------------------------------
const Intro = struct {
    started: Trigger = .{},
};

fn introTick() void {
    // on state enter, enable input and draw initial text
    if (state.intro.started.now()) {
        // sndClear();
        gfxClearSprites();
        state.gfx.fadein.start();
        state.input.enable();
        gfxClear(TileCodeSpace, ColorCodeDefault);
        gfxText(.{3,0}, "1UP   HIGH SCORE   2UP");
        gfxColorScore(.{6,1}, ColorCodeDefault, 0);
        if (state.game.hiscore > 0) {
            gfxColorScore(.{16,1}, ColorCodeDefault, state.game.hiscore);
        }
        gfxText(.{7,5}, "CHARACTER / NICKNAME");
        gfxText(.{3,35}, "CREDIT 0");
    }

    // draw the animated 'ghost... name... nickname' lines
    var delay: u32 = 0;
    const names = [_][]const u8 { "-SHADOW", "-SPEEDY", "-BASHFUL", "-POKEY" };
    const nicknames = [_][]const u8 { "BLINKY", "PINKY", "INKY", "CLYDE" };
    for (names) |name, i| {
        const color: u8 = 2 * @intCast(u8,i) + 1;
        const y: i16 = 3 * @intCast(i16,i) + 6;
        
        // 2*3 tiles ghost image
        delay += 30;
        if (state.intro.started.afterOnce(delay)) {
            gfxColorTile(.{4,y+0}, color, TileCodeGhost+0); gfxColorTile(.{5,y+0}, color, TileCodeGhost+1);
            gfxColorTile(.{4,y+1}, color, TileCodeGhost+2); gfxColorTile(.{5,y+1}, color, TileCodeGhost+3);
            gfxColorTile(.{4,y+2}, color, TileCodeGhost+4); gfxColorTile(.{5,y+2}, color, TileCodeGhost+5);
        }
        // after 1 second, the name of the ghost
        delay += 60;
        if (state.intro.started.afterOnce(delay)) {
            gfxColorText(.{7,y+1}, color, name);
        }
        // after 0.5 seconds, the nickname of the ghost
        delay += 30;
        if (state.intro.started.afterOnce(delay)) {
            gfxColorText(.{17,y+1}, color, nicknames[i]);
        }
    }

    // . 10 PTS
    // o 50 PTS
    delay += 60;
    if (state.intro.started.afterOnce(delay)) {
        gfxColorTile(.{10,24}, ColorCodeDot, TileCodeDot);
        gfxText(.{12,24}, "10 \x5D\x5E\x5F");
        gfxColorTile(.{10,26}, ColorCodeDot, TileCodePill);
        gfxText(.{12,26}, "50 \x5D\x5E\x5F");
    }

    // blinking "press any key" text
    delay += 60;
    if (state.intro.started.after(delay)) {
        if (0 != (state.intro.started.since() & 0x20)) {
            gfxColorText(.{3,31}, 3, "                       ");
        }
        else {
            gfxColorText(.{3,31}, 3, "PRESS ANY KEY TO START!");
        }
    }

    // if a key is pressed, advance to game state
    if (state.input.anykey) {
        state.input.disable();
        state.gfx.fadeout.start();
        state.game.started.startAfter(FadeTicks);
    }
}

//--- input system -------------------------------------------------------------
const Input = struct {
    enabled: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    esc: bool = false,
    anykey: bool = false,

    fn enable(self: *Input) void {
        self.enabled = true;
    }
    fn disable(self: *Input) void {
        self.* = .{};
    }
    fn dir(self: *Input, default_dir: Dir) Dir {
        if (self.enabled) {
            if (self.up) { return .Up; }
            else if (self.down) { return .Down; }
            else if (self.left) { return .Left; }
            else if (self.right) { return .Right; }
        }
        return default_dir;
    }
    fn onKey(self: *Input, keycode: sapp.Keycode, key_pressed: bool) void {
        if (self.enabled) {
            self.anykey = key_pressed;
            switch (keycode) {
                .W, .UP,    => self.up = key_pressed,
                .S, .DOWN,  => self.down = key_pressed,
                .A, .LEFT,  => self.left = key_pressed,
                .D, .RIGHT, => self.right = key_pressed,
                .ESCAPE     => self.esc = key_pressed,
                else => {}
            }
        }
    }
};

//--- time-trigger system ------------------------------------------------------
const Trigger = struct {
    const DisabledTicks = 0xFF_FF_FF_FF;

    tick: u32 = DisabledTicks,

    // set trigger to next tick
    fn start(t: *Trigger) void {
        t.tick = state.timing.tick + 1;
    }
    // set trigger to a future tick
    fn startAfter(t: *Trigger, ticks: u32) void {
        t.tick = state.timing.tick + ticks;
    }
    // disable a trigger
    fn disable(t: *Trigger) void {
        t.tick = DisabledTicks;
    }
    // check if trigger is triggered in current game tick
    fn now(t: Trigger) bool {
        return t.tick == state.timing.tick;
    }
    // return number of ticks since a time trigger was triggered
    fn since(t: Trigger) u32 {
        if (state.timing.tick >= t.tick) {
            return state.timing.tick - t.tick;
        }
        else {
            return DisabledTicks;
        }
    }
    // check if a time trigger is between begin and end tick
    fn between(t: Trigger, begin: u32, end: u32) bool {
        assert(begin < end);
        if (t.tick != DisabledTicks) {
            const ticks = since(t);
            return (ticks >= begin) and (ticks < end);
        }
        else {
            return false;
        }
    }
    // check if a time trigger was triggered exactly N ticks ago
    fn afterOnce(t: Trigger, ticks: u32) bool {
        return since(t) == ticks;
    }
    // check if a time trigger was triggered more than N ticks ago
    fn after(t: Trigger, ticks: u32) bool {
        const s = since(t);
        if (s != DisabledTicks) {
            return s >= ticks;
        }
        else {
            return false;
        }
    }
    // same as between(t, 0, ticks)
    fn before(t: Trigger, ticks: u32) bool {
        const s = since(t);
        if (s != DisabledTicks) {
            return s < ticks;
        }
        else {
            return false;
        }
    }
};

//--- rendering system ---------------------------------------------------------
const TileWidth = 8;            // width/height of a background tile in pixels
const TileHeight = 8;
const SpriteWidth = 16;         // width/height of a sprite in pixels
const SpriteHeight = 16;
const DisplayTilesX = 28;       // display width/height in number of tiles
const DisplayTilesY = 36;
const DisplayPixelsX = DisplayTilesX * TileWidth;
const DisplayPixelsY = DisplayTilesY * TileHeight;
const TileTextureWidth = 256 * TileWidth;
const TileTextureHeight = TileHeight + SpriteHeight;
const NumSprites = 8;
const MaxVertices = ((DisplayTilesX*DisplayTilesY) + NumSprites + NumDebugMarkers) * 6;

const Gfx = struct {
    // vertex-structure for rendering background tiles and sprites
    const Vertex = packed struct {
        x: f32, y: f32,     // 2D-pos
        u: f32, v: f32,     // texcoords
        attr: u32,          // color code and opacity
    };

    // a 'hardware sprite' struct
    const Sprite = struct {
        enabled: bool = false,
        tile: u8 = 0,
        color: u8 = 0,
        flipx: bool = false,
        flipy: bool = false,
        pos: ivec2 = ivec2{0,0},
    };

    // fade in/out
    fadein: Trigger = .{},
    fadeout: Trigger = .{},
    fade: u8 = 0xFF,

    // 'hardware sprites' (meh, array default initialization sure looks awkward...)
    sprites: [NumSprites]Sprite = [_]Sprite{.{}} ** NumSprites,

    // tile- and color-buffer
    tile_ram: [DisplayTilesY][DisplayTilesX]u8 = undefined,
    color_ram: [DisplayTilesY][DisplayTilesX]u8 = undefined,

    // sokol-gfx objects
    pass_action: sg.PassAction = .{},
    offscreen: struct {
        vbuf: sg.Buffer = .{},
        tile_img: sg.Image = .{},
        palette_img: sg.Image = .{},
        render_target: sg.Image = .{},
        pip: sg.Pipeline = .{},
        pass: sg.Pass = .{},
        bind: sg.Bindings = .{},
    } = .{},
    display: struct {
        quad_vbuf: sg.Buffer = .{},
        pip: sg.Pipeline = .{},
        bind: sg.Bindings = .{},
    } = .{},

    // upload-buffer for dynamically generated tile- and sprite-vertices
    num_vertices: u32 = 0,
    vertices: [MaxVertices]Vertex = undefined,

    // scratch-space for decoding tile ROM dumps into a GPU texture
    tile_pixels: [TileTextureHeight][TileTextureWidth]u8 = undefined,
    
    // scratch space for decoding color+palette ROM dumps into a GPU texture
    color_palette: [256]u32 = undefined,
};

fn gfxInit() void {
    sg.setup(.{
        .buffer_pool_size = 2,
        .image_pool_size = 3,
        .shader_pool_size = 2,
        .pipeline_pool_size = 2,
        .pass_pool_size = 1,
        .context = sgapp.context()
    });
    gfxDecodeTiles();
    gfxDecodeColorPalette();
    gfxCreateResources();
}

fn gfxShutdown() void {
    sg.shutdown();
}

fn gfxClear(tile_code: u8, color_code: u8) void {
    var y: u32 = 0;
    while (y < DisplayTilesY): (y += 1) {
        var x: u32 = 0;
        while (x < DisplayTilesX): (x += 1) {
            state.gfx.tile_ram[y][x] = tile_code;
            state.gfx.color_ram[y][x] = color_code;
        }
    }
}

fn gfxClearPlayfieldToColor(color_code: u8) void {
    var y: usize = 3;
    while (y < (DisplayTilesY-2)): (y += 1) {
        var x: usize = 0;
        while (x < DisplayTilesX): (x += 1) {
            state.gfx.color_ram[y][x] = color_code;
        }
    }
}

fn gfxTile(pos: ivec2, tile_code: u8) void {
    state.gfx.tile_ram[@intCast(usize,pos[1])][@intCast(usize,pos[0])] = tile_code;
}

fn gfxColor(pos: ivec2, color_code: u8) void {
    state.gfx.color_ram[@intCast(usize,pos[1])][@intCast(usize,pos[0])] = color_code;
}

fn gfxColorTile(pos: ivec2, color_code: u8, tile_code: u8) void {
    gfxTile(pos, tile_code);
    gfxColor(pos, color_code);
}

fn gfxToNamcoChar(c: u8) u8 {
    return switch (c) {
        ' ' => 64,
        '/' => 58,
        '-' => 59,
        '"' => 38,
        '!' => 'Z'+1,
        else => c
    };
}

fn gfxChar(pos: ivec2, chr: u8) void {
    gfxTile(pos, gfxToNamcoChar(chr));
}

fn gfxColorChar(pos: ivec2, color_code: u8, chr: u8) void {
    gfxChar(pos, chr);
    gfxColor(pos, color_code);
}

fn gfxColorText(pos: ivec2, color_code: u8, text: []const u8) void {
    var p = pos;
    for (text) |chr| {
        if (p[0] < DisplayTilesX) {
            gfxColorChar(p, color_code, chr);
            p[0] += 1;
        }
        else {
            break;
        }
    }
}

fn gfxText(pos: ivec2, text: []const u8) void {
    var p = pos;
    for (text) |chr| {
        if (p[0] < DisplayTilesX) {
            gfxChar(p, chr);
            p[0] += 1;
        }
        else {
            break;
        }
    }
}

// print colored score number into tile+color buffers from right to left(!),
// scores are /10, the last printed number is always 0, 
// a zero-score will print as '00' (this is the same as on
// the Pacman arcade machine)
fn gfxColorScore(pos: ivec2, color_code: u8, score: u32) void {
    var p = pos;
    var s = score;
    gfxColorChar(p, color_code, '0');
    p[0] -= 1;
    var digit: u32 = 0;
    while (digit < 8): (digit += 1) {
        // FIXME: should this narrowing cast not be necessary?
        const chr: u8 = @intCast(u8, s % 10) + '0';
        if (validTilePos(p)) {
            gfxColorChar(p, color_code, chr);
            p[0] -= 1;
            s /= 10;
            if (0 == score) {
                break;
            }
        }
    }
}

// draw a colored tile-quad arranged as:
// |t+1|t+0|
// |t+3|t+2|
//
// This is (for instance) used to render the current "lives" and fruit
// symbols at the lower border.
//
fn gfxColorTileQuad(pos: ivec2, color_code: u8, tile_code: u8) void {
    var yy: i16 = 0;
    while (yy < 2): (yy += 1) {
        var xx: i16 = 0;
        while (xx < 2): (xx += 1) {
            const t: u8 = tile_code + @intCast(u8,yy)*2 + (1 - @intCast(u8,xx));
            gfxColorTile(pos + ivec2{xx,yy}, color_code, t);
        }
    }
}


fn gfxClearSprites() void {
    for (state.gfx.sprites) |*spr| {
        spr.* = .{};
    }
}

// adjust viewport so that aspect ration is always correct
fn gfxAdjustViewport(canvas_width: i32, canvas_height: i32) void {
    assert((canvas_width > 0) and (canvas_height > 0));
    const fwidth = @intToFloat(f32, canvas_width);
    const fheight = @intToFloat(f32, canvas_height);
    const canvas_aspect = fwidth / fheight;
    const playfield_aspect = @intToFloat(f32, DisplayTilesX) / DisplayTilesY;
    const border = 10;
    if (playfield_aspect < canvas_aspect) {
        const vp_y: i32 = border;
        const vp_h: i32 = canvas_height - 2*border;
        const vp_w: i32 = @floatToInt(i32, fheight * playfield_aspect) - 2*border;
        // FIXME: why is /2 not possible here?
        const vp_x: i32 = (canvas_width - vp_w) >> 1;
        sg.applyViewport(vp_x, vp_y, vp_w, vp_h, true);
    }
    else {
        const vp_x: i32 = border;
        const vp_w: i32 = canvas_width - 2*border;
        const vp_h: i32 = @floatToInt(i32, fwidth / playfield_aspect) - 2*border;
        // FIXME: why is /2 not possible here?
        const vp_y: i32 = (canvas_height - vp_h) >> 1;
        sg.applyViewport(vp_x, vp_y, vp_w, vp_h, true);
    }
}

fn gfxFrame() void {
    // handle fade-in/out
    gfxUpdateFade();

    // render tile- and sprite-vertices and upload into vertex buffer
    state.gfx.num_vertices = 0;
    gfxAddPlayfieldVertices();
    gfxAddSpriteVertices();
    gfxAddDebugMarkerVertices();
    if (state.gfx.fade > 0) {
        gfxAddFadeVertices();
    }
    sg.updateBuffer(state.gfx.offscreen.vbuf, &state.gfx.vertices, @intCast(i32, state.gfx.num_vertices * @sizeOf(Gfx.Vertex)));

    // render tiles and sprites into offscreen render target
    sg.beginPass(state.gfx.offscreen.pass, state.gfx.pass_action);
    sg.applyPipeline(state.gfx.offscreen.pip);
    sg.applyBindings(state.gfx.offscreen.bind);
    // FIXME: sokol-gfx should use unsigned params here
    sg.draw(0, @intCast(i32, state.gfx.num_vertices), 1);
    sg.endPass();

    // upscale-render the offscreen render target into the display framebuffer
    const canvas_width = sapp.width();
    const canvas_height = sapp.height();
    sg.beginDefaultPass(state.gfx.pass_action, canvas_width, canvas_height);
    gfxAdjustViewport(canvas_width, canvas_height);
    sg.applyPipeline(state.gfx.display.pip);
    sg.applyBindings(state.gfx.display.bind);
    sg.draw(0, 4, 1);
    sg.endPass();
    sg.commit();
}

fn gfxAddVertex(x: f32, y: f32, u: f32, v: f32, color_code: u32, opacity: u32) void {
    var vtx: *Gfx.Vertex = &state.gfx.vertices[state.gfx.num_vertices];
    state.gfx.num_vertices += 1;
    vtx.x = x;
    vtx.y = y;
    vtx.u = u;
    vtx.v = v;
    vtx.attr = (opacity<<8)|color_code;
}

fn gfxAddTileVertices(x: u32, y: u32, tile_code: u32, color_code: u32) void {
    const dx = 1.0 / @intToFloat(f32, DisplayTilesX);
    const dy = 1.0 / @intToFloat(f32, DisplayTilesY);
    const dtx = @intToFloat(f32, TileWidth) / TileTextureWidth;
    const dty = @intToFloat(f32, TileHeight) / TileTextureHeight;

    const x0 = @intToFloat(f32, x) * dx;
    const x1 = x0 + dx;
    const y0 = @intToFloat(f32, y) * dy;
    const y1 = y0 + dy;
    const tx0 = @intToFloat(f32, tile_code) * dtx;
    const tx1 = tx0 + dtx;
    const ty0: f32 = 0.0;
    const ty1 = dty;

    //  x0,y0
    //  +-----+
    //  | *   |
    //  |   * |
    //  +-----+
    //          x1,y1
    gfxAddVertex(x0, y0, tx0, ty0, color_code, 0xFF);
    gfxAddVertex(x1, y0, tx1, ty0, color_code, 0xFF);
    gfxAddVertex(x1, y1, tx1, ty1, color_code, 0xFF);
    gfxAddVertex(x0, y0, tx0, ty0, color_code, 0xFF);
    gfxAddVertex(x1, y1, tx1, ty1, color_code, 0xFF);
    gfxAddVertex(x0, y1, tx0, ty1, color_code, 0xFF);
}

fn gfxUpdateFade() void {
    if (state.gfx.fadein.before(FadeTicks)) {
        const t = @intToFloat(f32, state.gfx.fadein.since()) / FadeTicks;
        state.gfx.fade = @floatToInt(u8, 255.0 * (1.0 - t));
    }
    if (state.gfx.fadein.afterOnce(FadeTicks)) {
        state.gfx.fade = 0;
    }
    if (state.gfx.fadeout.before(FadeTicks)) {
        const t = @intToFloat(f32, state.gfx.fadeout.since()) / FadeTicks;
        state.gfx.fade = @floatToInt(u8, 255.0 * t);
    }
    if (state.gfx.fadeout.afterOnce(FadeTicks)) {
        state.gfx.fade = 255;
    }
}

fn gfxAddPlayfieldVertices() void {
    var y: u32 = 0;
    while (y < DisplayTilesY): (y += 1) {
        var x: u32 = 0;
        while (x < DisplayTilesX): (x += 1) {
            const tile_code = state.gfx.tile_ram[y][x];
            const color_code = state.gfx.color_ram[y][x] & 0x1F;
            gfxAddTileVertices(x, y, tile_code, color_code);
        }
    }
}

fn gfxAddSpriteVertices() void {
    const dx = 1.0 / @intToFloat(f32, DisplayPixelsX);
    const dy = 1.0 / @intToFloat(f32, DisplayPixelsY);
    const dtx = @intToFloat(f32, SpriteWidth) / TileTextureWidth;
    const dty = @intToFloat(f32, SpriteHeight) / TileTextureHeight;
    for (state.gfx.sprites) |*spr| {
        if (spr.enabled) {
            const xx0 = @intToFloat(f32, spr.pos[0]) * dx;
            const xx1 = xx0 + dx*SpriteWidth;
            const yy0 = @intToFloat(f32, spr.pos[1]) * dy;
            const yy1 = yy0 + dy*SpriteHeight;

            const x0 = if (spr.flipx) xx1 else xx0;
            const x1 = if (spr.flipx) xx0 else xx1;
            const y0 = if (spr.flipy) yy1 else yy0;
            const y1 = if (spr.flipy) yy0 else yy1;

            const tx0 = @intToFloat(f32, spr.tile) * dtx;
            const tx1 = tx0 + dtx;
            const ty0 = @intToFloat(f32, TileHeight) / TileTextureHeight;
            const ty1 = ty0 + dty;

            gfxAddVertex(x0, y0, tx0, ty0, spr.color, 0xFF);
            gfxAddVertex(x1, y0, tx1, ty0, spr.color, 0xFF);
            gfxAddVertex(x1, y1, tx1, ty1, spr.color, 0xFF);
            gfxAddVertex(x0, y0, tx0, ty0, spr.color, 0xFF);
            gfxAddVertex(x1, y1, tx1, ty1, spr.color, 0xFF);
            gfxAddVertex(x0, y1, tx0, ty1, spr.color, 0xFF);
        }
    }
}

fn gfxAddDebugMarkerVertices() void {
    // FIXME
}

fn gfxAddFadeVertices() void {
    // sprite tile 64 is a special opaque sprite
    const dtx = @intToFloat(f32, SpriteWidth) / TileTextureWidth;
    const dty = @intToFloat(f32, SpriteHeight) / TileTextureHeight;
    const tx0 = 64 * dtx;
    const tx1 = tx0 + dtx;
    const ty0 = @intToFloat(f32, TileHeight) / TileTextureHeight;
    const ty1 = ty0 + dty;

    const fade = state.gfx.fade;
    gfxAddVertex(0.0, 0.0, tx0, ty0, 0, fade);
    gfxAddVertex(1.0, 0.0, tx1, ty0, 0, fade);
    gfxAddVertex(1.0, 1.0, tx1, ty1, 0, fade);
    gfxAddVertex(0.0, 0.0, tx0, ty0, 0, fade);
    gfxAddVertex(1.0, 1.0, tx1, ty1, 0, fade);
    gfxAddVertex(0.0, 1.0, tx0, ty1, 0, fade);
}

//  8x4 tile decoder (taken from: https://github.com/floooh/chips/blob/master/systems/namco.h)
//
//  This decodes 2-bit-per-pixel tile data from Pacman ROM dumps into
//  8-bit-per-pixel texture data (without doing the RGB palette lookup,
//  this happens during rendering in the pixel shader).
//
//  The Pacman ROM tile layout isn't exactly strightforward, both 8x8 tiles
//  and 16x16 sprites are built from 8x4 pixel blocks layed out linearly
//  in memory, and to add to the confusion, since Pacman is an arcade machine
//  with the display 90 degree rotated, all the ROM tile data is counter-rotated.
//
//  Tile decoding only happens once at startup from ROM dumps into a texture.
//
fn gfxDecodeTile8x4(
    tile_code: u32,     // the source tile code
    src: []const u8,    // encoded source tile data
    src_stride: u32,    // stride and offset in encoded tile data
    src_offset: u32,
    dst_x: u32,         // x/y position in target texture
    dst_y: u32)
void {
    var x: u32 = 0;
    while (x < TileWidth): (x += 1) {
        const ti = tile_code * src_stride + src_offset + (7 - x);
        var y: u3 = 0;
        while (y < (TileHeight/2)): (y += 1) {
            const p_hi: u8 = (src[ti] >> (7 - y)) & 1;
            const p_lo: u8 = (src[ti] >> (3 - y)) & 1;
            const p: u8 = (p_hi << 1) | p_lo;
            state.gfx.tile_pixels[dst_y + y][dst_x + x] = p;
        }
    }
}

// decode an 8x8 tile into the tile texture upper 8 pixels
const TileRom = @embedFile("roms/pacman_tiles.rom");
fn gfxDecodeTile(tile_code: u32) void {
    const x = tile_code * TileWidth;
    const y0 = 0;
    const y1 = TileHeight / 2;
    gfxDecodeTile8x4(tile_code, TileRom, 16, 8, x, y0);
    gfxDecodeTile8x4(tile_code, TileRom, 16, 0, x, y1);
}

// decode a 16x16 sprite into the tile textures lower 16 pixels
const SpriteRom = @embedFile("roms/pacman_sprites.rom");
fn gfxDecodeSprite(sprite_code: u32) void {
    const x0 = sprite_code * SpriteWidth;
    const x1 = x0 + TileWidth;
    const y0 = TileHeight;
    const y1 = y0 + (TileHeight / 2);
    const y2 = y1 + (TileHeight / 2);
    const y3 = y2 + (TileHeight / 2);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64, 40, x0, y0);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64,  8, x1, y0);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64, 48, x0, y1);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64, 16, x1, y1);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64, 56, x0, y2);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64, 24, x1, y2);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64, 32, x0, y3);
    gfxDecodeTile8x4(sprite_code, SpriteRom, 64,  0, x1, y3);
}

// decode the Pacman tile- and sprite-ROM-dumps into an 8-bpp linear texture
fn gfxDecodeTiles() void {
    var tile_code: u32 = 0;
    while (tile_code < 256): (tile_code += 1) {
        gfxDecodeTile(tile_code);
    }
    var sprite_code: u32 = 0;
    while (sprite_code < 64): (sprite_code += 1) {
        gfxDecodeSprite(sprite_code);
    }
    // write a special 16x16 block which will be used for the fade effect
    var y: u32 = TileHeight;
    while (y < TileTextureHeight): (y += 1) {
        var x: u32 = 64 * SpriteWidth;
        while (x < (65 * SpriteWidth)): (x += 1) {
            state.gfx.tile_pixels[y][x] = 1;
        }
    }
}

// decode the Pacman color palette into a palette texture, on the original
// hardware, color lookup happens in two steps, first through 256-entry
// palette which indirects into a 32-entry hardware-color palette
// (of which only 16 entries are used on the Pacman hardware)
//
fn gfxDecodeColorPalette() void {
    // Expand the 8-bit palette ROM items into RGBA8 items.
    // The 8-bit palette item bits are packed like this:
    // 
    // | 7| 6| 5| 4| 3| 2| 1| 0|
    // |B1|B0|G2|G1|G0|R2|R1|R0|
    //
    // Intensities for the 3 bits are: 0x97 + 0x47 + 0x21
    const color_rom = @embedFile("roms/pacman_hwcolors.rom");
    var hw_colors: [32]u32 = undefined;
    for (hw_colors) |*pt, i| {
        const rgb = color_rom[i];
        const r: u32 = ((rgb>>0)&1)*0x21 + ((rgb>>1)&1)*0x47 + ((rgb>>2)&1)*0x97;
        const g: u32 = ((rgb>>3)&1)*0x21 + ((rgb>>4)&1)*0x47 + ((rgb>>5)&1)*0x97;
        const b: u32 =                     ((rgb>>6)&1)*0x47 + ((rgb>>7)&1)*0x97;
        pt.* = 0xFF_00_00_00 | (b<<16) | (g<<8) | r;
    }

    // build 256-entry from indirection palette ROM
    const palette_rom = @embedFile("roms/pacman_palette.rom");
    for (state.gfx.color_palette) |*pt, i| {
        pt.* = hw_colors[palette_rom[i] & 0xF];
        // first color in each color block is transparent
        if ((i & 3) == 0) {
            pt.* &= 0x00_FF_FF_FF;
        }
    }
}

fn gfxCreateResources() void {
    // pass action for clearing background to black
    state.gfx.pass_action.colors[0] = .{
        .action = .CLEAR,
        .val = .{ 0.0, 0.0, 0.0, 1.0 }
    };

    // create a dynamic vertex buffer for the tile and sprite quads
    state.gfx.offscreen.vbuf = sg.makeBuffer(.{
        .usage = .STREAM,
        .size = @sizeOf(@TypeOf(state.gfx.vertices))
    });

    // create a quad-vertex-buffer for rendering the offscreen render target to the display
    const quad_verts = [_]f32{ 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0 };
    state.gfx.display.quad_vbuf = sg.makeBuffer(.{
        .content = &quad_verts,
        .size = @sizeOf(@TypeOf(quad_verts))
    });

    // create pipeline and shader for rendering into offscreen render target
    // NOTE: initializating structs with embedded arrays isn't great yet in Zig
    // because arrays aren't "filled up" with default items.
    {
        var shd_desc: sg.ShaderDesc = .{};
        shd_desc.attrs[0] = .{ .name = "pos", .sem_name = "POSITION" };
        shd_desc.attrs[1] = .{ .name = "uv_in", .sem_name = "TEXCOORD", .sem_index = 0 };
        shd_desc.attrs[2] = .{ .name = "data_in", .sem_name = "TEXCOORD", .sem_index = 1 };
        shd_desc.fs.images[0] = .{ .name = "tile_tex", .type = ._2D };
        shd_desc.fs.images[1] = .{ .name = "pal_tex", .type = ._2D };
        shd_desc.vs.source = switch(sg.queryBackend()) {
            .D3D11 => undefined,
            .GLCORE33 => @embedFile("shaders/offscreen_vs.v330.glsl"),
            else => unreachable,
        };
        shd_desc.fs.source = switch(sg.queryBackend()) {
            .D3D11 => undefined,
            .GLCORE33 => @embedFile("shaders/offscreen_fs.v330.glsl"),
            else => unreachable,
        };
        var pip_desc: sg.PipelineDesc = .{
            .shader = sg.makeShader(shd_desc),
            .blend = .{
                .enabled = true,
                .color_format = .RGBA8,
                .depth_format = .NONE,
                .src_factor_rgb = .SRC_ALPHA,
                .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA
            }
        };
        pip_desc.layout.attrs[0].format = .FLOAT2;
        pip_desc.layout.attrs[1].format = .FLOAT2;
        pip_desc.layout.attrs[2].format = .UBYTE4N;
        state.gfx.offscreen.pip = sg.makePipeline(pip_desc);
    }

    // create pipeline and shader for rendering into display
    {
        var shd_desc: sg.ShaderDesc = .{};
        shd_desc.attrs[0] = .{ .name = "pos", .sem_name = "POSITION" };
        shd_desc.fs.images[0] = .{ .name = "tex", .type = ._2D };
        shd_desc.vs.source = switch(sg.queryBackend()) {
            .D3D11 => undefined,
            .GLCORE33 => @embedFile("shaders/display_vs.v330.glsl"),
            else => unreachable
        };
        shd_desc.fs.source = switch(sg.queryBackend()) {
            .D3D11 => undefined,
            .GLCORE33 => @embedFile("shaders/display_fs.v330.glsl"),
            else => unreachable
        };
        var pip_desc: sg.PipelineDesc = .{
            .shader = sg.makeShader(shd_desc),
            .primitive_type = .TRIANGLE_STRIP,
        };
        pip_desc.layout.attrs[0].format = .FLOAT2;
        state.gfx.display.pip = sg.makePipeline(pip_desc);
    }

    // create a render-target image with a fixed upscale ratio
    state.gfx.offscreen.render_target = sg.makeImage(.{
        .render_target = true,
        .width = DisplayPixelsX * 2,
        .height = DisplayPixelsY * 2,
        .pixel_format = .RGBA8,
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE
    });

    // a pass object for rendering into the offscreen render target
    {
        var pass_desc: sg.PassDesc = .{};
        pass_desc.color_attachments[0].image = state.gfx.offscreen.render_target;
        state.gfx.offscreen.pass = sg.makePass(pass_desc);
    }

    // create the decoded tile+sprite texture
    {
        var img_desc: sg.ImageDesc = .{
            .width = TileTextureWidth,
            .height = TileTextureHeight,
            .pixel_format = .R8,
            .min_filter = .NEAREST,
            .mag_filter = .NEAREST,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        };
        img_desc.content.subimage[0][0] = .{
            .ptr = &state.gfx.tile_pixels,
            .size = @sizeOf(@TypeOf(state.gfx.tile_pixels))
        };
        state.gfx.offscreen.tile_img = sg.makeImage(img_desc);
    }

    // create the color-palette texture
    {
        var img_desc: sg.ImageDesc = .{
            .width = 256,
            .height = 1,
            .pixel_format = .RGBA8,
            .min_filter = .NEAREST,
            .mag_filter = .NEAREST,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        };
        img_desc.content.subimage[0][0] = .{
            .ptr = &state.gfx.color_palette,
            .size = @sizeOf(@TypeOf(state.gfx.color_palette))
        };
        state.gfx.offscreen.palette_img = sg.makeImage(img_desc);
    }

    // setup resource binding structs
    state.gfx.offscreen.bind.vertex_buffers[0] = state.gfx.offscreen.vbuf;
    state.gfx.offscreen.bind.fs_images[0] = state.gfx.offscreen.tile_img;
    state.gfx.offscreen.bind.fs_images[1] = state.gfx.offscreen.palette_img;
    state.gfx.display.bind.vertex_buffers[0] = state.gfx.display.quad_vbuf;
    state.gfx.display.bind.fs_images[0] = state.gfx.offscreen.render_target;
}

//--- sokol-app callbacks ------------------------------------------------------
export fn init() void {
    stm.setup();
    gfxInit();
    if (DbgSkipIntro) {
        state.game.started.start();
    }
    else {
        state.intro.started.start();
    }
}

export fn frame() void {

    // run the game at a fixed tick rate regardless of frame rate
    var frame_time_ns = stm.ns(stm.laptime(&state.timing.laptime_store));
    // clamp max frame duration (so the timing isn't messed up when stepping in debugger)
    if (frame_time_ns > MaxFrameTimeNS) {
        frame_time_ns = MaxFrameTimeNS;
    }

    state.timing.tick_accum += @floatToInt(i32, frame_time_ns);
    while (state.timing.tick_accum > -TickToleranceNS) {
        state.timing.tick_accum -= TickDurationNS;
        state.timing.tick += 1;

        // check for game state change
        if (state.intro.started.now()) {
            state.gamestate = .Intro;
        }
        if (state.game.started.now()) {
            state.gamestate = .Game;
        }

        // call the top-level gamestate tick function
        switch (state.gamestate) {
            .Intro => introTick(),
            .Game => gameTick(),
        }
    }
    gfxFrame();
}

export fn input(ev: ?*const sapp.Event) void {
    const event = ev.?;
    if ((event.type == .KEY_DOWN) or (event.type == .KEY_UP)) {
        const key_pressed = event.type == .KEY_DOWN;
        state.input.onKey(event.key_code, key_pressed);
    }
}

export fn cleanup() void {
    gfxShutdown();
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = input,
        .cleanup_cb = cleanup,
        .width = 2 * DisplayPixelsX,
        .height = 2 * DisplayPixelsY,
        .window_title = "pacman.zig"
    });
}
