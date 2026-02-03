function control2magnet()
% control2magnet.m
% Serial TX: "a,b\n" where a,b in [-100,100]
% Wave mode: BLUE/RED independent absolute params:
%   period (s), x-offset (unit-selectable), y-offset, magnitude
% x-offset unit:
%   - seconds (s)
%   - percent of period (% of T)
%   - half-period units (k * T/2)
% Manual mode: sliders set a,b directly in [-100,100]
% Plot y-lim fixed to [-150,150]
% Hz: computed from Arduino timestamp (first field of RX line: t_ms,...)

%% ========= USER SETTINGS =========
PORT = "/dev/cu.usbmodem1020BA0ABA902";
BAUD = 2000000;
TX_HZ = 50;
Y_LIM = [-150, 150];
SHOW_LAST_SEC = 10;
% =================================

%% --- Open serial (serialport preferred, fallback to serial) ---
useSerialport = exist("serialport","file") == 2;
if useSerialport
    sp = serialport(PORT, BAUD, "Timeout", 0.02);
    configureTerminator(sp, "LF");
    flush(sp);
else
    sp = serial(PORT, "BaudRate", BAUD, "Terminator", "LF", "Timeout", 0.02); %#ok<SER>
    fopen(sp);
end
cleaner = onCleanup(@() cleanupSerial(sp, useSerialport)); %#ok<NASGU>

%% ----- State -----
st.running  = false;
st.mode     = 1;  % 1=wave, 2=manual
st.waveType = 1;  % 1=sine,2=square,3=ramp
st.t0       = tic;

% BLUE absolute params
st.blue.period = 2.0;
st.blue.yoff   = 0.0;
st.blue.mag    = 50.0;
st.blue.xmode  = 1;     % 1=seconds, 2=%period, 3=half-periods
st.blue.xval   = 0.0;   % numeric value in selected mode

% RED absolute params
st.red.period  = 2.0;
st.red.yoff    = 0.0;
st.red.mag     = 50.0;
st.red.xmode   = 1;     % 1=seconds, 2=%period, 3=half-periods
st.red.xval    = 0.0;   % numeric value in selected mode

% Manual values
st.a_man = 0;
st.b_man = 0;

% RX Hz estimation
rx.last_t_ms = NaN;
rx.hz_ema    = NaN;
rx.alpha     = 0.2;

% Buffers
N = 800;
buf.t  = nan(1,N);
buf.a  = nan(1,N);
buf.b  = nan(1,N);

%% ----- Figure & Axes -----
fig = figure('Name','2-magnet control (a=blue, b=red)', ...
    'Position',[60 60 1380 820], 'Color','w', 'CloseRequestFcn',@onClose);

% Magnet axes (top)
axM = axes('Parent',fig,'Position',[0.36 0.80 0.62 0.16]);
axis(axM,[0 10 0 3]); axis(axM,'off'); hold(axM,'on');
drawMagnet(axM, 2.5,1.5,1.0,[0 0.45 0.95],'BLUE (a)');
drawMagnet(axM, 7.5,1.5,1.0,[0.9 0.1 0.1],'RED (b)');

% Wave axes (bottom)
ax = axes('Parent',fig,'Position',[0.36 0.10 0.62 0.68]);
hold(ax,'on'); grid(ax,'on');
ylim(ax,Y_LIM); xlim(ax,[-SHOW_LAST_SEC 0]);
xlabel(ax,'time (s, relative)'); ylabel(ax,'signal');
hA = plot(ax,nan,nan,'Color',[0 0.45 0.95],'LineWidth',2);
hB = plot(ax,nan,nan,'Color',[0.9 0.1 0.1],'LineWidth',2);

%% ===== UI layout constants (COMPACT + 2 COLUMNS) =====
BG = 'w';
TXT = 'k';                    % force black text
FS_LBL = 9;
FS_CTL = 9;

% Left panel width is ~0.33 of figure; we use pixel layout:
x0 = 15;
panelW = 330;
gapY = 6;
hLbl = 14;
hCtl = 20;

% Two columns inside left panel (BLUE left, RED right)
colGap = 10;
colW = floor((panelW - colGap)/2);
xBlue = x0;
xRed  = x0 + colW + colGap;

% Start y (top-down)
y = 780;

%% ----- Header / common controls (full width) -----
uicontrol(fig,'Style','text','Position',[x0 y panelW hLbl], ...
    'String','rx Hz (from Arduino timestamp)', ...
    'HorizontalAlignment','left','BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

txtHz = uicontrol(fig,'Style','text','Position',[x0 y panelW 18], ...
    'String','--', 'FontSize',11,'FontWeight','bold', ...
    'HorizontalAlignment','left','BackgroundColor',BG,'ForegroundColor',TXT);
y = y - (18 + 2*gapY);

txtAB = uicontrol(fig,'Style','text','Position',[x0 y panelW 18], ...
    'String','a=0, b=0', 'FontSize',10, ...
    'HorizontalAlignment','left','BackgroundColor',BG,'ForegroundColor',TXT);
y = y - (18 + 2*gapY);

btnRun = uicontrol(fig,'Style','togglebutton','Position',[x0 y panelW 26], ...
    'String','START','FontWeight','bold', 'FontSize',10, 'Callback',@onRunToggle);
y = y - (26 + 2*gapY);

uicontrol(fig,'Style','text','Position',[x0 y panelW hLbl], ...
    'String','Mode', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

popMode = uicontrol(fig,'Style','popupmenu','Position',[x0 y panelW hCtl], ...
    'String',{'Wave','Manual'}, 'Value',st.mode, 'Callback',@onMode, 'FontSize',FS_CTL);
y = y - (hCtl + 2*gapY);

uicontrol(fig,'Style','text','Position',[x0 y panelW hLbl], ...
    'String','Wave type (common)', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

popWave = uicontrol(fig,'Style','popupmenu','Position',[x0 y panelW hCtl], ...
    'String',{'Sine','Square','Ramp'}, 'Value',st.waveType, 'Callback',@onWaveType, 'FontSize',FS_CTL);
y = y - (hCtl + 2*gapY);

%% ----- Two-column section titles -----
uicontrol(fig,'Style','text','Position',[xBlue y colW hLbl], ...
    'String','BLUE (a)', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL,'FontWeight','bold');
uicontrol(fig,'Style','text','Position',[xRed y colW hLbl], ...
    'String','RED (b)', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL,'FontWeight','bold');
y = y - (hLbl + 2*gapY);

%% ===== BLUE / RED wave controls in two columns =====
% Row helper: label + control per column
% BLUE period
uicontrol(fig,'Style','text','Position',[xBlue y colW hLbl], ...
    'String','period (s)', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
uicontrol(fig,'Style','text','Position',[xRed y colW hLbl], ...
    'String','period (s)', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

editBluePeriod = uicontrol(fig,'Style','edit','Position',[xBlue y colW hCtl], ...
    'String',num2str(st.blue.period), 'Callback',@onBluePeriod, 'FontSize',FS_CTL);
editRedPeriod = uicontrol(fig,'Style','edit','Position',[xRed y colW hCtl], ...
    'String',num2str(st.red.period), 'Callback',@onRedPeriod, 'FontSize',FS_CTL);
y = y - (hCtl + 2*gapY);

% x offset mode
uicontrol(fig,'Style','text','Position',[xBlue y colW hLbl], ...
    'String','x offset mode', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
uicontrol(fig,'Style','text','Position',[xRed y colW hLbl], ...
    'String','x offset mode', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

popBlueXmode = uicontrol(fig,'Style','popupmenu','Position',[xBlue y colW hCtl], ...
    'String',{'sec','%T','k*T/2'}, 'Value',st.blue.xmode, 'Callback',@onBlueXmode, 'FontSize',FS_CTL);
popRedXmode = uicontrol(fig,'Style','popupmenu','Position',[xRed y colW hCtl], ...
    'String',{'sec','%T','k*T/2'}, 'Value',st.red.xmode, 'Callback',@onRedXmode, 'FontSize',FS_CTL);
y = y - (hCtl + 2*gapY);

% x offset value
uicontrol(fig,'Style','text','Position',[xBlue y colW hLbl], ...
    'String','x offset value', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
uicontrol(fig,'Style','text','Position',[xRed y colW hLbl], ...
    'String','x offset value', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

editBlueXval = uicontrol(fig,'Style','edit','Position',[xBlue y colW hCtl], ...
    'String',num2str(st.blue.xval), 'Callback',@onBlueXval, 'FontSize',FS_CTL);
editRedXval = uicontrol(fig,'Style','edit','Position',[xRed y colW hCtl], ...
    'String',num2str(st.red.xval), 'Callback',@onRedXval, 'FontSize',FS_CTL);
y = y - (hCtl + 2*gapY);

% y offset
uicontrol(fig,'Style','text','Position',[xBlue y colW hLbl], ...
    'String','y offset', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
uicontrol(fig,'Style','text','Position',[xRed y colW hLbl], ...
    'String','y offset', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

slBlueYoff = uicontrol(fig,'Style','slider','Position',[xBlue y colW 16], ...
    'Min',-150,'Max',150,'Value',st.blue.yoff);
slRedYoff  = uicontrol(fig,'Style','slider','Position',[xRed y colW 16], ...
    'Min',-150,'Max',150,'Value',st.red.yoff);
y = y - (16 + 2*gapY);

% magnitude
uicontrol(fig,'Style','text','Position',[xBlue y colW hLbl], ...
    'String','magnitude', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
uicontrol(fig,'Style','text','Position',[xRed y colW hLbl], ...
    'String','magnitude', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

slBlueMag = uicontrol(fig,'Style','slider','Position',[xBlue y colW 16], ...
    'Min',0,'Max',150,'Value',st.blue.mag);
slRedMag  = uicontrol(fig,'Style','slider','Position',[xRed y colW 16], ...
    'Min',0,'Max',150,'Value',st.red.mag);
y = y - (16 + 3*gapY);

%% ----- Manual controls (full width, compact) -----
uicontrol(fig,'Style','text','Position',[x0 y panelW hLbl], ...
    'String','Manual a (blue) [-100..100]', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

slA = uicontrol(fig,'Style','slider','Position',[x0 y panelW 16], ...
    'Min',-100,'Max',100,'Value',0, 'Callback',@onManualA);
y = y - (16 + 2*gapY);

uicontrol(fig,'Style','text','Position',[x0 y panelW hLbl], ...
    'String','Manual b (red) [-100..100]', 'HorizontalAlignment','left', ...
    'BackgroundColor',BG,'ForegroundColor',TXT,'FontSize',FS_LBL);
y = y - (hLbl + gapY);

slB = uicontrol(fig,'Style','slider','Position',[x0 y panelW 16], ...
    'Min',-100,'Max',100,'Value',0, 'Callback',@onManualB);

applyEnableState();

%% ----- Timer (TX loop) -----
tmr = timer('ExecutionMode','fixedRate', 'Period',1/TX_HZ, 'TimerFcn',@onTick);

%% ===== nested callbacks =====

    function onRunToggle(src,~)
        st.running = logical(get(src,'Value'));
        if st.running
            set(src,'String','STOP');
            st.t0 = tic;
            buf.t(:)=nan; buf.a(:)=nan; buf.b(:)=nan;
            rx.last_t_ms=NaN; rx.hz_ema=NaN;
            start(tmr);
        else
            set(src,'String','START');
            stop(tmr);
            safeWrite(0,0);
        end
    end

    function onMode(~,~)
        st.mode = get(popMode,'Value');
        applyEnableState();
    end

    function onWaveType(~,~), st.waveType = get(popWave,'Value'); end

    function onBluePeriod(~,~)
        v = str2double(get(editBluePeriod,'String'));
        if isnan(v) || v <= 0.05, v = 2.0; end
        st.blue.period = v;
        set(editBluePeriod,'String',num2str(st.blue.period));
    end

    function onRedPeriod(~,~)
        v = str2double(get(editRedPeriod,'String'));
        if isnan(v) || v <= 0.05, v = 2.0; end
        st.red.period = v;
        set(editRedPeriod,'String',num2str(st.red.period));
    end

    function onBlueXmode(~,~)
        st.blue.xmode = get(popBlueXmode,'Value');
    end

    function onRedXmode(~,~)
        st.red.xmode = get(popRedXmode,'Value');
    end

    function onBlueXval(~,~)
        v = str2double(get(editBlueXval,'String'));
        if isnan(v), v = 0; end
        st.blue.xval = v;
        set(editBlueXval,'String',num2str(st.blue.xval));
    end

    function onRedXval(~,~)
        v = str2double(get(editRedXval,'String'));
        if isnan(v), v = 0; end
        st.red.xval = v;
        set(editRedXval,'String',num2str(st.red.xval));
    end

    function onManualA(~,~), st.a_man = round(get(slA,'Value')); end
    function onManualB(~,~), st.b_man = round(get(slB,'Value')); end

    function applyEnableState()
        isWave = (st.mode == 1);

        set(popWave,'Enable', tern(isWave,'on','off'));

        % BLUE wave controls
        set(editBluePeriod,'Enable', tern(isWave,'on','off'));
        set(popBlueXmode,'Enable',  tern(isWave,'on','off'));
        set(editBlueXval,'Enable',  tern(isWave,'on','off'));
        set(slBlueYoff,'Enable',    tern(isWave,'on','off'));
        set(slBlueMag,'Enable',     tern(isWave,'on','off'));

        % RED wave controls
        set(editRedPeriod,'Enable', tern(isWave,'on','off'));
        set(popRedXmode,'Enable',   tern(isWave,'on','off'));
        set(editRedXval,'Enable',   tern(isWave,'on','off'));
        set(slRedYoff,'Enable',     tern(isWave,'on','off'));
        set(slRedMag,'Enable',      tern(isWave,'on','off'));

        % Manual sliders
        set(slA,'Enable', tern(~isWave,'on','off'));
        set(slB,'Enable', tern(~isWave,'on','off'));
    end

    function onTick(~,~)
        if ~ishandle(fig) || ~st.running, return; end

        % read sliders continuously
        st.blue.yoff = get(slBlueYoff,'Value');
        st.blue.mag  = get(slBlueMag,'Value');
        st.red.yoff  = get(slRedYoff,'Value');
        st.red.mag   = get(slRedMag,'Value');

        t = toc(st.t0);

        if st.mode == 1
            phaseBlue_s = xoffset_to_seconds(st.blue.xmode, st.blue.xval, st.blue.period);
            phaseRed_s  = xoffset_to_seconds(st.red.xmode,  st.red.xval,  st.red.period);

            a = waveValue_channel(t, st.blue.period, phaseBlue_s, st.blue.yoff, st.blue.mag);
            b = waveValue_channel(t, st.red.period,  phaseRed_s,  st.red.yoff,  st.red.mag);
        else
            a = st.a_man;
            b = st.b_man;
        end

        if ~isfinite(a), a = 0; end
        if ~isfinite(b), b = 0; end

        set(txtAB,'String',sprintf('a=%.1f, b=%.1f', a, b));

        % send (clamped)
        a_cmd = int32(max(-100,min(100,round(a))));
        b_cmd = int32(max(-100,min(100,round(b))));
        safeWrite(a_cmd, b_cmd);

        % plot values
        pushSample(t, double(a), double(b));
        updatePlot();

        % read RX lines
        pollRx();
    end

    function y = waveValue_channel(t, T, phase_s, y0, mag)
        if ~isfinite(T) || T <= 0.05, T = 2.0; end
        if ~isfinite(phase_s), phase_s = 0.0; end
        if ~isfinite(y0), y0 = 0.0; end
        if ~isfinite(mag), mag = 0.0; end

        tt = t + phase_s;

        switch st.waveType
            case 1 % sine
                y = y0 + mag*sin(2*pi*tt/T);
            case 2 % square
                s = sin(2*pi*tt/T);
                y = y0 + mag*(2*(s >= 0) - 1);
            case 3 % ramp
                ph = mod(tt, T)/T;
                y = y0 + mag*(2*ph - 1);
        end
    end

    function safeWrite(a_cmd, b_cmd)
        msg = sprintf('%d,%d\n', a_cmd, b_cmd);
        try
            if useSerialport
                write(sp, uint8(msg), "uint8");
            else
                fprintf(sp, '%s', msg);
            end
        catch
            st.running = false;
            set(btnRun,'Value',0,'String','START');
            try, stop(tmr); end %#ok<TRYNC>
        end
    end

    function pollRx()
        for k = 1:30
            line = "";
            try
                if useSerialport
                    if sp.NumBytesAvailable <= 0, break; end
                    line = readline(sp);
                else
                    if sp.BytesAvailable <= 0, break; end %#ok<*BDSCA>
                    line = fgetl(sp);
                end
            catch
                break;
            end
            if strlength(string(line)) < 1, continue; end
            parts = split(string(strtrim(line)), ",");
            t_ms = str2double(parts(1));
            if isnan(t_ms), continue; end

            if ~isnan(rx.last_t_ms)
                dt = t_ms - rx.last_t_ms;
                if dt > 0
                    hz_now = 1000.0/dt;
                    if isnan(rx.hz_ema)
                        rx.hz_ema = hz_now;
                    else
                        rx.hz_ema = rx.alpha*hz_now + (1-rx.alpha)*rx.hz_ema;
                    end
                end
            end
            rx.last_t_ms = t_ms;

            if ~isnan(rx.hz_ema)
                set(txtHz,'String',sprintf('%.2f Hz', rx.hz_ema));
            end
        end
    end

    function pushSample(t, a, b)
        buf.t = [buf.t(2:end), t];
        buf.a = [buf.a(2:end), a];
        buf.b = [buf.b(2:end), b];
    end

    function updatePlot()
        t = buf.t;
        idx = find(~isnan(t),1,'last');
        if isempty(idx), return; end
        tnow = t(idx);
        tr = t - tnow;
        set(hA,'XData',tr,'YData',buf.a);
        set(hB,'XData',tr,'YData',buf.b);
        xlim(ax,[-SHOW_LAST_SEC 0]);
        ylim(ax,Y_LIM);
        drawnow limitrate;
    end

    function onClose(~,~)
        try
            if isvalid(tmr), stop(tmr); delete(tmr); end
        catch
        end
        try, safeWrite(0,0); end %#ok<TRYNC>
        delete(fig);
    end

end

%% ===== helpers =====
function out = tern(cond, a, b)
if cond, out = a; else, out = b; end
end

function drawMagnet(ax, cx, cy, r, col, label)
th = linspace(0,2*pi,200);
plot(ax, cx + r*cos(th), cy + r*sin(th), 'Color',col, 'LineWidth',4);
text(ax, cx, cy, label, 'HorizontalAlignment','center', 'FontWeight','bold');
end

function phase_s = xoffset_to_seconds(mode, xval, T)
if ~isfinite(T) || T <= 0, T = 1.0; end
if ~isfinite(xval), xval = 0.0; end
switch mode
    case 1
        phase_s = xval;
    case 2
        phase_s = (xval/100.0)*T;
    case 3
        phase_s = xval*(T/2.0);
    otherwise
        phase_s = 0.0;
end
end

function cleanupSerial(sp, useSerialport)
try
    if useSerialport
        clear sp;
    else
        fclose(sp);
        delete(sp);
    end
catch
end
end
