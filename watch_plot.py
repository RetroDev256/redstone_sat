import matplotlib.pyplot as plt
import re
import time

def parse_kissat(file_path):
    times = []
    remaining_vars = []

    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    float_re = re.compile(r'^[0-9]+\.[0-9]+$')

    with open(file_path, 'r') as file:
        for line in file:
            clean = ansi_escape.sub('', line).strip()
            parts = clean.split()

            if not parts or parts[0] != 'c':
                continue

            # first float = time
            t = None
            for p in parts:
                if float_re.match(p):
                    t = float(p)
                    break
            if t is None:
                continue

            # last % → previous field = remaining vars
            percent_indices = [
                i for i, p in enumerate(parts) if p.endswith('%')
            ]
            if not percent_indices:
                continue

            i = percent_indices[-1]
            try:
                rv = int(parts[i - 1])
            except (IndexError, ValueError):
                continue

            times.append(t)
            remaining_vars.append(rv)

    return times, remaining_vars


def live_plot(file_path, interval=3):
    plt.ion()
    fig, ax = plt.subplots(figsize=(12, 7))

    line, = ax.plot([], [], '-o',
                    linewidth=2,
                    color='darkblue',
                    markersize=4,
                    markerfacecolor='red',
                    markeredgecolor='red')

    ax.set_xscale('log')
    ax.set_xlabel('Time (seconds)')
    ax.set_ylabel('Remaining Variables')
    ax.set_title('Kissat Progress (Live)')
    ax.grid(True, which="both", linestyle='--', alpha=0.6)

    while True:
        times, remaining_vars = parse_kissat(file_path)

        if times:
            line.set_data(times, remaining_vars)
            ax.relim()
            ax.autoscale_view()

        plt.pause(interval)


if __name__ == "__main__":
    live_plot("kissat.txt", interval=3)

