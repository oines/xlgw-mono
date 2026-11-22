import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, write, type ListResult, type Row } from "./api";

export function useList<T extends Row = Row>(
  path: string,
  enabled = true,
  poll = false,
) {
  return useQuery({
    queryKey: ["list", path],
    queryFn: () => api<ListResult<T>>(path),
    enabled,
    refetchInterval: poll ? 15000 : false,
  });
}

export function useObject<T = Row>(path: string, enabled = true) {
  return useQuery({
    queryKey: ["object", path],
    queryFn: () => api<T>(path),
    enabled,
  });
}

export function useWrite() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: ({
      path,
      data,
      method,
    }: {
      path: string;
      data?: unknown;
      method?: string;
    }) => write<Row>(path, data, method),
    onSuccess: () => {
      void client.invalidateQueries();
    },
  });
}
