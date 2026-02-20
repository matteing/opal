import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useMemo,
  type FC,
  type ReactNode,
} from "react";
import { useStdout } from "ink";
import { throttle } from "lodash-es";

export interface ViewportSize {
  width: number;
  height: number;
}

const ViewportContext = createContext<ViewportSize>({ width: 80, height: 24 });

export const useViewport = (): ViewportSize & {
  /** Convert a percentage (0–100) of viewport width to columns. */
  pctW: (pct: number) => number;
  /** Convert a percentage (0–100) of viewport height to rows. */
  pctH: (pct: number) => number;
} => {
  const size = useContext(ViewportContext);
  return useMemo(
    () => ({
      ...size,
      pctW: (pct: number) => Math.floor((size.width * pct) / 100),
      pctH: (pct: number) => Math.floor((size.height * pct) / 100),
    }),
    [size],
  );
};

export const ViewportProvider: FC<{ children: ReactNode }> = ({ children }) => {
  const { stdout } = useStdout();

  const [size, setSize] = useState<ViewportSize>(() => ({
    width: stdout?.columns ?? 80,
    height: stdout?.rows ?? 24,
  }));

  const onResize = useMemo(
    () =>
      throttle(() => {
        if (stdout) {
          setSize({ width: stdout.columns, height: stdout.rows });
        }
      }, 100),
    [stdout],
  );

  useEffect(() => {
    if (!stdout) return;

    stdout.on("resize", onResize);
    return () => {
      stdout.off("resize", onResize);
      onResize.cancel();
    };
  }, [stdout, onResize]);

  return <ViewportContext value={size}>{children}</ViewportContext>;
};
