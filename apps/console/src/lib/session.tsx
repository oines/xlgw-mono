import { createContext, useContext, useState, type ReactNode } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError, write, type User, type School } from "./api";

const SessionContext = createContext<{
  user: User | null;
  school: School | undefined;
  loading: boolean;
  error: Error | null;
  login: (account: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  refresh: () => void;
}>({
  user: null,
  school: undefined,
  loading: true,
  error: null,
  login: async () => {},
  logout: async () => {},
  refresh: () => {},
});

export function SessionProvider({ children }: { children: ReactNode }) {
  const client = useQueryClient();
  const [loggedOut, setLoggedOut] = useState(false);
  const me = useQuery({
    queryKey: ["me"],
    queryFn: () => api<User>("/me"),
    retry: false,
    enabled: !loggedOut,
  });
  const school = useQuery({
    queryKey: ["school"],
    queryFn: () => api<School>("/school"),
    retry: false,
  });
  const login = async (account: string, password: string) => {
    const response = await write<{ user: User; token: string }>("/auth/login", {
      account,
      password,
    });
    setLoggedOut(false);
    client.setQueryData(["me"], response.user);
  };
  const logout = async () => {
    await write("/auth/logout");
    setLoggedOut(true);
    client.removeQueries({
      predicate: (query) => query.queryKey[0] !== "school",
    });
  };
  const error =
    me.error instanceof ApiError && me.error.status === 401 ? null : me.error;
  return (
    <SessionContext.Provider
      value={{
        user:
          loggedOut || (me.error instanceof ApiError && me.error.status === 401)
            ? null
            : (me.data ?? null),
        school: school.data,
        loading: me.isLoading,
        error,
        login,
        logout,
        refresh: () => {
          void me.refetch();
          void school.refetch();
        },
      }}
    >
      {children}
    </SessionContext.Provider>
  );
}

export const useSession = () => useContext(SessionContext);
