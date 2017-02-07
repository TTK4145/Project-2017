import  std.algorithm,
        std.concurrency,
        std.conv,
        std.datetime,
        std.file,
        std.getopt,
        std.math,
        std.process,
        std.random,
        std.range,
        std.socket,
        std.stdio,
        std.uni,
        core.exception;

import timer_event;



///----------------------///
/// -----  CONFIG  ----- ///
///----------------------///

__gshared auto travelTimeBetweenFloors    = 2.seconds;
__gshared auto travelTimePassingFloor     = 500.msecs;
__gshared auto btnDepressedTime           = 200.msecs;

__gshared int numFloors = 4;

__gshared ushort port = 15657;

__gshared char off    = '-';
__gshared char on     = '*';

__gshared string[] key_orderButtons = [
    "qwertyui?",
    "?sdfghjkl",
    "zxcvbnm,.",
];
__gshared char key_stopButton   = 'p';
__gshared char key_obstruction  = '-';
__gshared char key_moveUp       = '9';
__gshared char key_moveStop     = '8';
__gshared char key_moveDown     = '7';


void loadConfig(string file){
    try {
        string[] configContents;

        int travelTimeBetweenFloors_ms;
        int travelTimePassingFloor_ms;
        int btnDepressedTime_ms;
        string key_ordersUp;
        string key_ordersDown;
        string key_ordersCab;

        configContents = file.readText.split;
        getopt( configContents,
            std.getopt.config.passThrough,
            "travelTimeBetweenFloors_ms",   &travelTimeBetweenFloors_ms,
            "travelTimePassingFloor_ms",    &travelTimePassingFloor_ms,
            "btnDepressedTime_ms",          &btnDepressedTime_ms,
            "numFloors",                    &numFloors,
            "com_port",                     &port,
            "light_off",                    &off,
            "light_on",                     &on,
            "key_ordersUp",                 &key_ordersUp,
            "key_ordersDown",               &key_ordersDown,
            "key_ordersCab",                &key_ordersCab,
            "key_stopButton",               &key_stopButton,
            "key_obstruction",              &key_obstruction,
            "key_moveUp",                   &key_moveUp,
            "key_moveStop",                 &key_moveStop,
            "key_moveDown",                 &key_moveDown,
        );

        travelTimeBetweenFloors    = travelTimeBetweenFloors_ms.msecs;
        travelTimePassingFloor     = travelTimePassingFloor_ms.msecs;
        btnDepressedTime           = btnDepressedTime_ms.msecs;
        key_orderButtons = [key_ordersUp, "?"~key_ordersDown, key_ordersCab];

    } catch(Exception e){
        writeln("Unable to load simulationElevator config (", e.msg, "), using defaults.");
    }
}






///-----------------------------///
/// -----  MESSAGE TYPES  ----- ///
///-----------------------------///


/// --- PANEL --- ///

struct StdinChar {
    char c;
    alias c this;
}

enum BtnAction {
    Press,
    Release,
    Toggle
}

struct OrderButton {
    int floor;
    int btnType;
    BtnAction action;
}

struct StopButton {
    BtnAction action;
    alias action this;
}

struct ObstructionSwitch {}


/// --- INTERFACE --- ///

// -- Write -- //

struct MotorDirection {
    Dirn dirn;
    alias dirn this;
}

struct OrderButtonLight {
    int floor;
    BtnType btnType;
    bool value;
}

struct FloorIndicator {
    int floor;
    alias floor this;
}

struct DoorLight {
    bool value;
    alias value this;
}

struct StopButtonLight {
    bool value;
    alias value this;
}

struct ReloadConfig {}

// -- Read -- //

struct OrderButtonRequest {
    int floor;
    BtnType btnType;
}

struct FloorSensorRequest {}

struct StopButtonRequest {}

struct ObstructionRequest {}


/// --- MOVEMENT --- ///

struct FloorArrival {
    int floor;
    alias floor this;
}

struct FloorDeparture {
    int floor;
    alias floor this;
}


///---------------------///
/// -----  TYPES  ----- ///
///---------------------///

enum Dirn {
    Down    = -1,
    Stop    = 0,
    Up      = 1,
}

enum BtnType {
    Up      = 0,
    Down    = 1,
    Cab     = 2,
}

final class SimulationState {
    this(Flag!"randomStart" randomStart, int numFloors){
        assert(2 <= numFloors  &&  numFloors <= 9);
        this.numFloors  = numFloors;
        orderButtons    = new bool[3][](numFloors);
        orderLights     = new bool[3][](numFloors);
        resetState();

        bg = new char[][](8, 27 + 4*numFloors);

        if(randomStart){
            prevFloor = uniform(0, numFloors);
            currFloor = dice(50, 50) ? -1 : prevFloor;
            if(currFloor == -1  &&  prevFloor == 0){
                departDirn = Dirn.Up;
            } else if(currFloor == -1  &&  prevFloor == numFloors-1){
                departDirn = Dirn.Down;
            } else {
                departDirn = dice(50, 50) ? Dirn.Up : Dirn.Down;
            }
            currDirn = Dirn.Stop;
        } else {
            currDirn    = Dirn.Stop;
            currFloor   = 0;
            departDirn  = Dirn.Up;
            prevFloor   = 0;
        }
        resetBg;
    }

    this(Flag!"randomStart" randomStart){
        this(randomStart, 4);
    }

    immutable int numFloors;

    bool[3][]   orderButtons;
    bool[3][]   orderLights;
    bool        stopButton;
    bool        stopButtonLight;
    bool        obstruction;
    bool        doorLight;
    int         floorIndicator;

    Dirn        currDirn;
    int         currFloor;      // 0..numFloors, or -1 when between floors
    Dirn        departDirn;     // Only Dirn.Up or Dirn.Down
    int         prevFloor;      // 0..numFloors, never -1

    char[][]    bg;
    int         printCount;

    invariant {
        assert(-1 <= currFloor  && currFloor < numFloors,
            "currFloor is not between -1..numFloors");
        assert(0 <= prevFloor  && prevFloor < numFloors,
            "prevFloor is not between 0..numFloors");
        assert(departDirn != Dirn.Stop,
            "departDirn is Dirn.Stop");
        assert(!(currFloor == -1  &&  departDirn == Dirn.Down  &&  prevFloor == 0),
            "Elevator is below the bottom floor");
        assert(!(currFloor == -1  &&  departDirn == Dirn.Up  &&  prevFloor == numFloors-1),
            "Elevator is above the top floor");
    }

    void resetState(){
        orderButtons.fill(false);
        orderLights.fill(false);
        stopButton      = false;
        stopButtonLight = false;
        obstruction     = false;
        doorLight       = false;
        floorIndicator  = 0;
        printCount      = 0;
    }

    void resetBg(){
        foreach(ref line; bg){
            foreach(ref c; line){
                c = ' ';
            }
        }
        bg[0][] = "+-----------+"   ~ "-".repeat(numFloors*4+1).join                      ~ "+            ";
        bg[1][] = "|           |"   ~ " ".repeat(numFloors*4+1).join                      ~ "|            ";
        bg[2][] = "| Floor     |  " ~ iota(0, numFloors).map!(to!string).join("   ")    ~ "  |            ";
        bg[3][] = "+-----------+"   ~ "-".repeat(numFloors*4+1).join                      ~ "+-----------+";
        bg[4][] = "| Hall Up   |"   ~ " ".repeat(numFloors*4+1).join                      ~ "| Door:     |";
        bg[5][] = "| Hall Down |"   ~ " ".repeat(numFloors*4+1).join                      ~ "| Stop:     |";
        bg[6][] = "| Cab       |"   ~ " ".repeat(numFloors*4+1).join                      ~ "| Obstr:    |";
        bg[7][] = "+-----------+"   ~ "-".repeat(numFloors*4+1).join                      ~ "+-----------+";

    }

    override string toString(){
        // Reset
        bg[1][13..14+numFloors*4] = " ".repeat(numFloors*4+1).join;
        foreach(f; 0..numFloors){
            bg[2][16+f*4] = ' ';
        }


        bg[2][16+floorIndicator*4]      = on;
        bg[4][$-3] = doorLight          ? on  : off;
        bg[5][$-3] = stopButtonLight    ? on  : off;
        bg[6][$-3] = obstruction        ? 'v' : '^';

        foreach(floor, lightsAtFloor; orderLights){
            foreach(btnType, lightEnabled; lightsAtFloor){
                if( (btnType == BtnType.Up  &&  floor == numFloors-1) ||
                    (btnType == BtnType.Down  &&  floor == 0)
                ){
                    continue;
                }
                bg[4+btnType][15+floor*4] = lightEnabled ? on : off;
            }
        }

        int elevatorPos;
        if(currFloor != -1){
            elevatorPos = 15+currFloor*4;
        } else {
            if(departDirn == Dirn.Up){
                elevatorPos = 17+prevFloor*4;
            }
            if(departDirn == Dirn.Down){
                elevatorPos = 13+prevFloor*4;
            }
        }
        bg[1][elevatorPos] = '#';
        if(currDirn == Dirn.Up){
            bg[1][elevatorPos+1] = '>';
        }
        if(currDirn == Dirn.Down){
            bg[1][elevatorPos-1] = '<';
        }

        auto c = (++printCount).to!(char[]);
        bg[7][$-1-c.length..$-1] = c[0..$];

        return bg.map!(a => a.to!string).reduce!((a, b) => a ~ "\n" ~ b);
    }

}






void main(string[] args){
    try {

    (args.length == 2 ? args[1] : "simulator.con").loadConfig;

    auto state = new SimulationState(Yes.randomStart, numFloors);
    void printState(){
        version(Posix){
            wait(spawnShell("clear"));
        } else version(Windows){
            wait(spawnShell("cls"));
        }
        state.writeln;
    }
    printState;
    

    auto stdinParseTid          = spawnLinked(&stdinParseProc, thisTid);
    auto stdinGetterTid         = spawnLinked(&stdinGetterProc, stdinParseTid);
    auto networkInterfaceTid    = spawnLinked(&networkInterfaceProc, thisTid);
    
    
    import core.thread : Thread;
    foreach(ref t; Thread.getAll){
        t.isDaemon = true;
    }    

    auto stateUpdated = false;

    while(true){
        if(stateUpdated){
            printState;
        }
        stateUpdated = true;
        
        receive(
            /// --- RESET --- ///

            (ReloadConfig r){
                (args.length == 2 ? args[1] : "simulator.con").loadConfig;
                state = new SimulationState(Yes.randomStart, numFloors);
            },


            /// --- WRITE --- ///

            (MotorDirection md){
                assert(Dirn.min <= md &&  md <= Dirn.max,
                    "Tried to set motor direction to invalid direction " ~ md.to!int.to!string);
                if(state.currDirn != md){
                    state.currDirn = md;

                    if(state.currFloor == -1){
                        deleteEvent(thisTid, typeid(FloorArrival), Delete.all);
                    } else {
                        deleteEvent(thisTid, typeid(FloorDeparture), Delete.all);
                    }

                    if(md != Dirn.Stop){
                        if(state.currFloor != -1){
                            // At a floor: depart this floor
                            addEvent(thisTid, travelTimePassingFloor, FloorDeparture(state.currFloor));
                            state.departDirn = md;
                        } else {
                            // Between floors
                            if(state.departDirn == md){
                                // Continue in that direction
                                addEvent(thisTid, travelTimeBetweenFloors, FloorArrival(state.prevFloor + md));
                            } else {
                                // Go back to previous floor
                                addEvent(thisTid, travelTimeBetweenFloors, FloorArrival(state.prevFloor));
                            }
                        }
                    }
                }
            },
            (OrderButtonLight obl){
                assert(0 <= obl.floor  &&  obl.floor < state.numFloors,
                    "Tried to set order button light at non-existent floor " ~ obl.floor.to!string);
                assert(0 <= obl.btnType  &&  obl.btnType <= BtnType.max,
                    "Tried to set order button light for invalid button type " ~ obl.btnType.to!int.to!string);
                state.orderLights[obl.floor][obl.btnType] = obl.value;
            },
            (FloorIndicator fi){
                assert(0 <= fi  &&  fi < state.numFloors,
                    "Tried to set floor indicator to non-existent floor " ~ fi.to!string);
                state.floorIndicator = fi;
            },
            (DoorLight dl){
                state.doorLight = dl;
            },
            (StopButtonLight sbl){
                state.stopButtonLight = sbl;
            },


            /// --- READ --- ///

            (Tid receiver, OrderButtonRequest req){
                stateUpdated = false;
                assert(0 <= req.floor  &&  req.floor < state.numFloors,
                    "Tried to read order button at non-existent floor " ~ req.floor.to!string);
                assert(0 <= req.btnType  &&  req.btnType <= BtnType.max,
                    "Tried to read order button for invalid button type " ~ req.btnType.to!int.to!string);
                if( (req.btnType == BtnType.Up && req.floor == state.numFloors-1) ||
                    (req.btnType == BtnType.Down && req.floor == 0)
                ){
                    receiver.send(false);
                } else {
                    receiver.send(state.orderButtons[req.floor][req.btnType]);
                }
            },
            (Tid receiver, FloorSensorRequest req){
                stateUpdated = false;
                receiver.send(state.currFloor);
            },
            (Tid receiver, StopButtonRequest req){
                stateUpdated = false;
                receiver.send(state.stopButton);
            },
            (Tid receiver, ObstructionRequest req){
                stateUpdated = false;
                receiver.send(state.obstruction);
            },




            /// --- PANEL INPUTS --- ///

            (OrderButton ob){
                if(ob.floor < state.numFloors){
                    final switch(ob.action) with(BtnAction){
                    case Press:
                        state.orderButtons[ob.floor][ob.btnType] = true;
                        break;
                    case Release:
                        state.orderButtons[ob.floor][ob.btnType] = false;
                        break;
                    case Toggle:
                        state.orderButtons[ob.floor][ob.btnType] = !state.orderButtons[ob.floor][ob.btnType];
                        break;
                    }
                }
            },
            (StopButton sb){
                final switch(sb.action) with(BtnAction){
                case Press:
                    state.stopButton = true;
                    break;
                case Release:
                    state.stopButton = false;
                    break;
                case Toggle:
                    state.stopButton = !state.stopButton;
                    break;
                }
            },
            (ObstructionSwitch os){
                state.obstruction = !state.obstruction;
            },


            /// --- MOVEMENT --- ///

            (FloorArrival f){
                assert(state.currDirn != Dirn.Stop,
                    "Elevator arrived at a floor with currDirn == Dirn.Stop");
                assert(0 <= f  &&  f <= state.numFloors,
                    "Elevator \"arrived\" at a non-existent floor\n");
                assert(
                    (state.currDirn == Dirn.Up   && f >= state.prevFloor) ||
                    (state.currDirn == Dirn.Down && f <= state.prevFloor),
                    "Elevator arrived at a floor in the opposite direction of travel\n");
                assert(abs(f - state.prevFloor) <= 1,
                    "Elevator skipped a floor");


                state.currFloor = f;
                state.prevFloor = f;
                addEvent(thisTid, travelTimePassingFloor, FloorDeparture(state.currFloor));
            },
            (FloorDeparture f){
                if(state.currDirn == Dirn.Down){
                    assert(0 < f,
                        "Elevator departed the bottom floor going downward\n");
                }
                if(state.currDirn == Dirn.Up){
                    assert(f < state.numFloors-1,
                        "Elevator departed the top floor going upward\n");
                }

                state.departDirn = state.currDirn;
                state.currFloor = -1;
                addEvent(thisTid, travelTimeBetweenFloors, FloorArrival(state.prevFloor + state.currDirn));
            },


            /// --- OTHER --- ///
            
            (LinkTerminated lt){
                assert(false, "Child thread terminated, shutting down...");
            },
            (Variant v){
                assert(false, "Received unknown type " ~ v.to!string ~ ", terminating...");
            }

        );
    }
    } catch(Throwable t){
        writeln(typeid(t).name, "@", t.file, "(", t.line, "): ", t.msg);
    }
}

version(Posix){
    import core.sys.posix.termios;
    __gshared termios oldt;
    __gshared termios newt;
    shared static this(){
        tcgetattr(0, &oldt);
        newt = oldt;
        newt.c_lflag &= ~(ICANON | ECHO);
        tcsetattr(0, TCSANOW, &newt);
    }
    shared static ~this(){
        tcsetattr(0, TCSANOW, &oldt);
    }
}

void stdinGetterProc(Tid receiver){
    try {
    version(Windows){
        import core.sys.windows.wincon;
        import core.sys.windows.winbase;

        SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), ENABLE_PROCESSED_INPUT);
        foreach(ubyte[] buf; stdin.byChunk(1)){
            SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), ENABLE_PROCESSED_INPUT);
            receiver.send(StdinChar(cast(char)buf[0]));
        }

    } else version(Posix){
        import core.stdc.stdio;

        while(true){
            receiver.send(StdinChar(cast(char)getchar()));
        }
    }
    } catch(Throwable t){
        writeln(typeid(t).name, "@", t.file, "(", t.line, "): ", t.msg);
    }
}


void stdinParseProc(Tid receiver){
    try {
    while(true){
        receive(
            (StdinChar c){
                foreach(int btnType, keys; key_orderButtons){
                    int floor = keys.countUntil(c.toLower).to!int;
                    if( (floor != -1) &&
                        !(btnType == BtnType.Up && c == keys[$-1]) &&
                        !(btnType == BtnType.Down && c == keys[0])
                    ){
                        if(c.isUpper){
                            receiver.send(OrderButton(floor, btnType, BtnAction.Toggle));
                        } else {
                            receiver.send(OrderButton(floor, btnType, BtnAction.Press));
                            addEvent(receiver, btnDepressedTime, OrderButton(floor, btnType, BtnAction.Release));
                        }
                    }
                }

                if(c.toLower == key_stopButton){
                    if(c.isUpper){
                        receiver.send(StopButton(BtnAction.Toggle));
                    } else {
                        receiver.send(StopButton(BtnAction.Press));
                        addEvent(receiver, btnDepressedTime, StopButton(BtnAction.Release));
                    }
                }

                if(c == key_obstruction){
                    receiver.send(ObstructionSwitch());
                }

                if(c == key_moveUp){
                    receiver.send(MotorDirection(Dirn.Up));
                }
                if(c == key_moveStop){
                    receiver.send(MotorDirection(Dirn.Stop));
                }
                if(c == key_moveDown){
                    receiver.send(MotorDirection(Dirn.Down));
                }
            }
        );
    }
    } catch(Throwable t){
        writeln(typeid(t).name, "@", t.file, "(", t.line, "): ", t.msg);
    }
}


void networkInterfaceProc(Tid receiver){
    try {
    
    Socket acceptSock = new TcpSocket();

    acceptSock.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    acceptSock.bind(new InternetAddress(port.to!ushort));
    acceptSock.listen(1);

    ubyte[4] buf;

    while(true){
        auto sock = acceptSock.accept();
        writeln("Connected");
        while(sock.isAlive){
            buf = 0;
            auto n = sock.receive(buf);

            if(n <= 0){
                writeln("Disconnected");
                sock.shutdown(SocketShutdown.BOTH);
                sock.close();
            } else {
                switch(buf[0]){
                case 0:
                    receiver.send(ReloadConfig());
                    break;
                case 1:
                    receiver.send(MotorDirection(
                        (buf[1] == 0)   ? Dirn.Stop :
                        (buf[1] < 128)  ? Dirn.Up   :
                                          Dirn.Down
                    ));
                    break;
                case 2:
                    receiver.send(OrderButtonLight(buf[2].to!int, cast(BtnType)buf[1], buf[3].to!bool));
                    break;
                case 3:
                    receiver.send(FloorIndicator(buf[1].to!int));
                    break;
                case 4:
                    receiver.send(DoorLight(buf[1].to!bool));
                    break;
                case 5:
                    receiver.send(StopButtonLight(buf[1].to!bool));
                    break;

                case 6:
                    receiver.send(thisTid, OrderButtonRequest(buf[2].to!int, cast(BtnType)buf[1]));
                    receive((bool v){
                        buf[1..$] = [v.to!ubyte, 0, 0];
                        sock.send(buf);
                    });
                    break;
                case 7:
                    receiver.send(thisTid, FloorSensorRequest());
                    receive((int f){
                        buf[1..$] = (f == -1) ? [0, 0, 0] : [1, cast(ubyte)f, 0];
                        sock.send(buf);
                    });
                    break;
                case 8:
                    receiver.send(thisTid, StopButtonRequest());
                    receive((bool v){
                        buf[1..$] = [v.to!ubyte, 0, 0];
                        sock.send(buf);
                    });
                    break;
                case 9:
                    receiver.send(thisTid, ObstructionRequest());
                    receive((bool v){
                        buf[1..$] = [v.to!ubyte, 0, 0];
                        sock.send(buf);
                    });
                    break;
                default:
                    break;
                }
            }
        }
    }
    
    } catch(Throwable t){
        writeln(typeid(t).name, "@", t.file, "(", t.line, "): ", t.msg);
    }
}















