import { useMemo, useState } from "react";
import {
  ArrowRight, BellSimple, CaretLeft, CaretRight, ChartBar, Check,
  CirclesFour, ClockCounterClockwise, Cpu, Database, Export, Factory,
  FunnelSimple, GearSix, HardDrives, Info, MapPin, Pulse, SquaresFour,
  Warning, X,
} from "@phosphor-icons/react";
import {
  CartesianGrid, Line, LineChart, ReferenceLine, ResponsiveContainer,
  Tooltip, XAxis, YAxis,
} from "recharts";

const navItems = [
  { label: "Incident Ledger", icon: Pulse },
  { label: "Command", icon: SquaresFour },
  { label: "Events", icon: CirclesFour },
  { label: "Anomalies", icon: Warning },
  { label: "Replay", icon: ClockCounterClockwise },
  { label: "Fleet", icon: Cpu },
  { label: "Dashboards", icon: ChartBar },
  { label: "Integrations", icon: HardDrives },
  { label: "Settings", icon: GearSix },
];

const incidents = [
  { id: "PS-8F2K7M9", time: "09:53:07", severity: "Critical", title: "Temperature threshold breach", place: "Nador Plant / Zone A", metric: "95.0 °C > 90.0 °C for 2m 15s", device: "sensor-1042", value: 95.0, threshold: 90, reason: "Value > threshold for 2m", delta: "+22.1", group: "Now" },
  { id: "PS-8F2K7M8", time: "09:51:12", severity: "High", title: "Vibration anomaly detected", place: "Nador Plant / Zone C", metric: "RMS 8.7 mm/s > 6.0 mm/s", device: "pump-807", value: 8.7, threshold: 6.0, reason: "Vibration outside baseline", delta: "+2.7", group: "Now" },
  { id: "PS-8F2K7M7", time: "09:50:41", severity: "High", title: "Pressure spike", place: "Nador Plant / Zone B", metric: "7.2 bar > 6.5 bar", device: "valve-219", value: 7.2, threshold: 6.5, reason: "Pressure above safe range", delta: "+0.7", group: "Now" },
  { id: "PS-8F2K7M6", time: "09:48:03", severity: "Medium", title: "Flow rate deviation", place: "Nador Plant / Zone A", metric: "-18% from baseline for 5m", device: "flow-044", value: 82, threshold: 85, reason: "Sustained baseline deviation", delta: "-18%", group: "Now" },
  { id: "PS-8F2K7M5", time: "09:45:22", severity: "Medium", title: "Temperature rising trend", place: "Nador Plant / Zone D", metric: "Rate of change 1.8 °C/min", device: "sensor-1180", value: 81.3, threshold: 90, reason: "Fast rising temperature", delta: "+8.7", group: "Now" },
  { id: "PS-8F2K7L4", time: "09:41:10", severity: "High", title: "Temperature threshold breach", place: "Nador Plant / Zone C", metric: "92.1 °C > 90.0 °C for 1m 05s", device: "sensor-0982", value: 92.1, threshold: 90, reason: "Value > threshold for 1m", delta: "+19.4", group: "Earlier today" },
  { id: "PS-8F2K7L3", time: "09:36:55", severity: "Medium", title: "Pressure fluctuation", place: "Nador Plant / Zone B", metric: "σ 1.2 bar > 1.0 bar", device: "valve-104", value: 6.1, threshold: 6.5, reason: "Unstable pressure signal", delta: "+0.8", group: "Earlier today" },
  { id: "PS-8F2K7L2", time: "09:32:18", severity: "Low", title: "Humidity high", place: "Nador Plant / Zone D", metric: "78% > 70%", device: "humidity-031", value: 78, threshold: 70, reason: "Humidity above range", delta: "+8", group: "Earlier today" },
  { id: "PS-8F2K7L1", time: "09:20:07", severity: "Medium", title: "Vibration rising trend", place: "Nador Plant / Zone A", metric: "Rate of change 0.9 mm/s/min", device: "pump-123", value: 5.8, threshold: 6, reason: "Fast rising vibration", delta: "+1.9", group: "Earlier today" },
  { id: "PS-8F2K7K0", time: "09:12:34", severity: "Low", title: "Signal quality degraded", place: "Nador Plant / Zone C", metric: "SNR 12 dB < 15 dB", device: "sensor-711", value: 12, threshold: 15, reason: "Weak gateway signal", delta: "-3", group: "Earlier today" },
];

const baseTrend = [
  ["09:38", 77.2], ["09:39", 78.0], ["09:40", 77.8], ["09:41", 78.4],
  ["09:42", 78.0], ["09:43", 78.2], ["09:44", 78.1], ["09:45", 79.0],
  ["09:46", 80.1], ["09:47", 82.0], ["09:48", 85.2], ["09:49", 88.4],
  ["09:50", 91.0], ["09:51", 92.1], ["09:52", 94.0], ["09:53", 95.0],
].map(([time, temperature]) => ({ time, temperature, baseline: 73.2 + (Number(time.slice(-2)) - 38) * 0.08 }));

const readings = [
  ["09:53:07", "95.0", "+22.1"], ["09:52:37", "94.3", "+21.4"],
  ["09:52:07", "93.1", "+20.2"], ["09:51:37", "92.0", "+19.1"],
  ["09:51:07", "90.5", "+17.6"],
];

const pipeline = [
  { name: "Ingestion", value: "24.8k/min", helper: "Events in", state: "healthy", icon: Factory },
  { name: "Raw", value: "99.94%", helper: "Success rate", state: "healthy", icon: HardDrives },
  { name: "Processing", value: "186 ms", helper: "End-to-end latency", state: "healthy", icon: Cpu },
  { name: "Storage", value: "99.98%", helper: "Write success", state: "healthy", icon: Database },
  { name: "DLQ", value: "23/min", helper: "Events in DLQ", state: "warning", icon: Warning },
];

function getSignalMeta(incident) {
  const title = incident.title.toLowerCase();
  if (title.includes("vibration")) return { label: "Vibration", unit: "mm/s" };
  if (title.includes("pressure")) return { label: "Pressure", unit: "bar" };
  if (title.includes("flow")) return { label: "Flow rate", unit: "%" };
  if (title.includes("humidity")) return { label: "Humidity", unit: "%" };
  if (title.includes("signal quality")) return { label: "Signal quality", unit: "dB" };
  return { label: "Temperature", unit: "°C" };
}

function Logo() {
  return <div className="brand"><Pulse size={27} weight="bold" aria-hidden="true" /><span>PulseStream</span></div>;
}

function Navigation({ active, onChange }) {
  return (
    <aside className="sidebar">
      <Logo />
      <nav aria-label="Primary navigation">
        {navItems.map(({ label, icon: Icon }) => (
          <button key={label} className={active === label ? "nav-item active" : "nav-item"} onClick={() => onChange(label)}>
            <Icon size={20} weight={active === label ? "fill" : "regular"} aria-hidden="true" /><span>{label}</span>
          </button>
        ))}
      </nav>
      <div className="operator"><span className="status-dot" aria-hidden="true" /><div><strong>On-call Engineer</strong><span>Nador Operations</span></div><CaretRight size={14} aria-hidden="true" /></div>
    </aside>
  );
}

function SystemPulse() {
  return (
    <header className="system-area">
      <div className="system-meta"><div><strong>System pulse</strong><span>Last updated: 09:53:12</span></div><time dateTime="2026-09-04T09:53:12+01:00">Fri, Sep 4, 2026&nbsp; 09:53</time></div>
      <div className="pulse-steps" aria-label="Pipeline health">
        {pipeline.map(({ name, value, helper, state, icon: Icon }, index) => (
          <div className={`pulse-step ${state}`} key={name}>
            <div className="pulse-icon"><Icon size={18} weight="bold" aria-hidden="true" /></div>
            <div className="pulse-copy"><strong>{name}</strong><b>{value}</b><span>{helper}</span></div>
            {index < pipeline.length - 1 && <div className="pulse-connector" aria-hidden="true" />}
          </div>
        ))}
      </div>
    </header>
  );
}

function SeverityBadge({ level }) {
  return <span className={`severity-text ${level.toLowerCase()}`}>{level}</span>;
}

function IncidentLedger({ selectedId, onSelect }) {
  const [filterOpen, setFilterOpen] = useState(false);
  const [severity, setSeverity] = useState("All");
  const filtered = severity === "All" ? incidents : incidents.filter((item) => item.severity === severity);
  return (
    <section className="ledger" aria-label="Anomaly ledger">
      <div className="ledger-head"><strong>Anomaly ledger</strong><button className="control-button" onClick={() => setFilterOpen(!filterOpen)} aria-expanded={filterOpen}><FunnelSimple size={16} aria-hidden="true" /> Filter <span className="count">2</span></button></div>
      {filterOpen && <div className="filter-bar" role="group" aria-label="Filter by severity">{["All", "Critical", "High", "Medium", "Low"].map((item) => <button key={item} className={severity === item ? "selected" : ""} onClick={() => setSeverity(item)}>{item}</button>)}</div>}
      <div className="ledger-scroll">
        {["Now", "Earlier today"].map((group) => {
          const items = filtered.filter((item) => item.group === group);
          if (!items.length) return null;
          return <div key={group}><div className="group-label">{group}</div>{items.map((incident) => (
            <button key={incident.id} className={`incident-row ${incident.severity.toLowerCase()} ${selectedId === incident.id ? "selected" : ""}`} onClick={() => onSelect(incident.id)}>
              <span className="severity-rail" aria-hidden="true" />
              <span className="incident-top"><time>{incident.time}</time><SeverityBadge level={incident.severity} /><strong>{incident.title}</strong><code>{incident.id}</code><CaretRight size={13} aria-hidden="true" /></span>
              <span className="incident-bottom"><span>{incident.place}</span><span>{incident.metric}</span></span>
            </button>
          ))}</div>;
        })}
      </div>
      <div className="ledger-foot"><span>Showing 1–{filtered.length} of 78</span><div className="pagination"><button aria-label="Previous page"><CaretLeft size={14} /></button><button className="current">1</button><button>2</button><button>3</button><span>…</span><button>8</button><button aria-label="Next page"><CaretRight size={14} /></button></div></div>
    </section>
  );
}

function SignalChart({ incident }) {
  const signal = getSignalMeta(incident);
  const factor = incident.id === incidents[0].id ? 1 : incident.value / 95;
  const data = baseTrend.map((point) => ({ ...point, temperature: Number((point.temperature * factor).toFixed(1)) }));
  const min = incident.value < 20 ? 0 : Math.max(0, Math.floor((incident.value - 35) / 10) * 10);
  const max = Math.max(100, Math.ceil((incident.value + 4) / 10) * 10);
  const domainMax = incident.value < 20 ? Math.ceil((incident.value + 2) / 2) * 2 : max;
  return (
    <div className="chart-wrap">
      <div className="chart-legend"><span className="solid-key" />{signal.label} ({signal.unit})<span className="dash-key baseline" />Baseline (p50)<span className="dash-key threshold" />Threshold ({incident.threshold})</div>
      <ResponsiveContainer width="100%" height={220}><LineChart data={data} margin={{ top: 18, right: 52, left: 0, bottom: 4 }}><CartesianGrid vertical={false} stroke="#e9ecef" /><XAxis dataKey="time" axisLine={{ stroke: "#aeb6bd" }} tickLine={false} tick={{ fill: "#69737c", fontSize: 11 }} interval={1} /><YAxis domain={[min, domainMax]} axisLine={false} tickLine={false} tick={{ fill: "#69737c", fontSize: 11 }} width={38} /><Tooltip contentStyle={{ border: "1px solid #dce1e5", borderRadius: 8, boxShadow: "none", fontSize: 12 }} formatter={(value) => [`${value} ${signal.unit}`, signal.label]} /><ReferenceLine y={incident.threshold} stroke="#e5484d" strokeDasharray="7 5" /><Line type="monotone" dataKey="baseline" stroke="#8c98a4" strokeDasharray="7 5" strokeWidth={1.4} dot={false} isAnimationActive={false} /><Line type="monotone" dataKey="temperature" stroke="#e5484d" strokeWidth={2.2} dot={false} activeDot={{ r: 5, strokeWidth: 2, fill: "#fff" }} isAnimationActive={false} /></LineChart></ResponsiveContainer>
      <div className="chart-endpoint" aria-label={`Latest ${signal.label.toLowerCase()} reading ${incident.value} ${signal.unit} at ${incident.time}`}><strong>{incident.value.toFixed(1)} {signal.unit}</strong><span>{incident.time}</span></div>
      <div className="chart-caption"><span className="critical-dot" />Breached for 2m 15s</div>
    </div>
  );
}

function EventContext({ incident }) {
  const details = [["Event ID", incident.id], ["Detected", `Sep 4, 2026 ${incident.time}`], ["First seen", "Sep 4, 2026 09:50:52"], ["Duration", "2m 15s (ongoing)"], ["Severity", incident.severity], ["Reason", incident.reason], ["Source topic", "telemetry.events.anomalies"], ["Correlation ID", "c8d9f3a2-7b15-4c6f-9f3a-a2d5e9b6a1f2c"]];
  return <section className="detail-panel context-panel"><h3>Event context</h3><dl>{details.map(([term, value]) => <div key={term}><dt>{term}</dt><dd className={term === "Severity" ? "critical-value" : ""}>{value}</dd></div>)}</dl></section>;
}

function RecentReadings({ incident }) {
  const multiplier = incident.value / 95;
  const signal = getSignalMeta(incident);
  return <section className="detail-panel readings-panel"><h3>Recent readings <span>({incident.device})</span></h3><table><thead><tr><th>Time</th><th>{signal.label} ({signal.unit})</th><th>Δ baseline</th></tr></thead><tbody>{readings.map(([time, value, delta]) => <tr key={time}><td>{time}</td><td>{(Number(value) * multiplier).toFixed(1)}</td><td>{delta}</td></tr>)}</tbody></table><button className="text-link">View in time explorer <Export size={14} /></button></section>;
}

function EventFlow() {
  const stages = [["09:50:52", "Ingestion", "Event received", "24.8k/min", "good"], ["09:50:52", "telemetry.events.raw", "Stored", "99.94%", "good"], ["09:50:52", "Telemetry Processor", "Processed", "186 ms", "good"], ["09:50:53", "telemetry.events.dlq", "—", "0/min", "good"], ["09:50:53", "telemetry.events.anomalies", "Anomaly published", "23/min", "critical"]];
  return <section className="detail-panel flow-panel"><h3>Event flow</h3><ol>{stages.map(([time, name, action, value, state]) => <li key={name} className={state}><span className="flow-node"><Check size={11} weight="bold" /></span><time>{time}</time><div><strong>{name}</strong><span>{action}</span></div><b>{value}</b></li>)}</ol></section>;
}

function InvestigationModal({ incident, onClose }) {
  const signal = getSignalMeta(incident);
  return <div className="modal-backdrop" role="presentation" onMouseDown={onClose}><section className="investigation-modal" role="dialog" aria-modal="true" aria-labelledby="investigation-title" onMouseDown={(event) => event.stopPropagation()}><button className="icon-button close" onClick={onClose} aria-label="Close investigation"><X size={20} /></button><span className="eyebrow">Investigation opened</span><h2 id="investigation-title">{incident.title}</h2><p>The event has been pinned to your active investigation. PulseStream preserved the raw payload, processing context, and anomaly evidence for this session.</p><div className="modal-grid"><div><Info size={20} /><span>Incident</span><strong>{incident.id}</strong></div><div><Pulse size={20} /><span>Signal</span><strong>{incident.value} {signal.unit}</strong></div><div><MapPin size={20} /><span>Location</span><strong>{incident.place}</strong></div></div><button className="primary-button" onClick={onClose}>Continue investigation <ArrowRight size={17} /></button></section></div>;
}

function IncidentDetail({ incident }) {
  const [acknowledged, setAcknowledged] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const signal = getSignalMeta(incident);
  const isTemperature = signal.label === "Temperature";
  return (
    <main className="detail">
      <div className="detail-head"><div><button className="back-link"><CaretLeft size={14} /> Back to ledger</button><div className="title-line"><span className="title-rail" /><h1>{incident.title}</h1></div><div className="title-meta"><span><Cpu size={15} />{incident.device}</span><span><MapPin size={15} />{incident.place}</span><SeverityBadge level={incident.severity} /></div></div><div className="detail-actions"><button className={acknowledged ? "secondary-button acknowledged" : "secondary-button"} onClick={() => setAcknowledged(!acknowledged)}><Check size={17} />{acknowledged ? "Acknowledged" : "Acknowledge"}</button><button className="primary-button" onClick={() => setModalOpen(true)}>Open investigation <ArrowRight size={17} /></button></div></div>
      <section className="evidence-panel"><div className="evidence-main"><h3>Signal evidence</h3><SignalChart incident={incident} /></div><aside className="impact"><h3>Why this matters</h3>{isTemperature ? <><p>Temperature exceeded the critical threshold of <strong>{incident.threshold}.0 °C</strong> for 2 minutes 15 seconds.</p><p>Sustained high temperature increases the risk of equipment damage or failure.</p></> : <><p><strong>{incident.title}</strong> remained outside the expected operating range.</p><p>{incident.reason}. Review the device and upstream gateway before escalating.</p></>}<h4>Impact</h4><ul><li><Warning size={17} />High risk of component degradation</li><li><Info size={17} />Potential unplanned downtime</li><li><Factory size={17} />Affects 1 device in Zone A</li></ul></aside></section>
      <div className="detail-grid"><EventContext incident={incident} /><RecentReadings incident={incident} /><EventFlow /></div>
      <footer className="timezone"><Info size={14} />All times are shown in UTC+1 (Africa/Casablanca)</footer>
      {modalOpen && <InvestigationModal incident={incident} onClose={() => setModalOpen(false)} />}
    </main>
  );
}

export function App() {
  const [activeNav, setActiveNav] = useState("Incident Ledger");
  const [selectedId, setSelectedId] = useState(incidents[0].id);
  const [notice, setNotice] = useState("");
  const selected = useMemo(() => incidents.find((item) => item.id === selectedId) || incidents[0], [selectedId]);
  const handleNav = (item) => { setActiveNav(item); if (item !== "Incident Ledger") { setNotice(`${item} is ready for the next PulseStream workspace.`); window.setTimeout(() => setNotice(""), 2400); } };
  return <div className="app-shell"><Navigation active={activeNav} onChange={handleNav} /><div className="workspace"><SystemPulse /><div className="content-grid"><IncidentLedger selectedId={selectedId} onSelect={setSelectedId} /><IncidentDetail key={selected.id} incident={selected} /></div></div>{notice && <div className="toast" role="status"><BellSimple size={17} />{notice}</div>}</div>;
}
