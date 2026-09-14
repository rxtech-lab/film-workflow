"use client";

import { useState, useTransition } from "react";
import { ConfirmDialog } from "./confirm-dialog";
import { deleteItem, deleteItemAndReturn } from "@/lib/marketplace/actions";

/**
 * Deleting an item takes its content file and its previews with it and nothing
 * comes back, so it asks twice: once by opening the dialog, and again for the
 * word typed back into it. The same two gates the macOS authoring list uses.
 */
export function DeleteMarketplaceItem({ id, title, className, disabled, returnToList = false, onError }: {
  id: string;
  title: string;
  className: string;
  disabled?: boolean;
  /** The item form deletes the page it is standing on, so it leaves for the list. */
  returnToList?: boolean;
  onError?: (message: string) => void;
}) {
  const [confirming, setConfirming] = useState(false);
  const [pending, startTransition] = useTransition();
  return (
    <>
      <button type="button" className={className} disabled={disabled || pending} onClick={() => setConfirming(true)}>Delete</button>
      {confirming ? (
        <ConfirmDialog
          title={`Delete “${title}”?`}
          body={<>This removes the item, its content file and its previews from the marketplace. They cannot be recovered. An item someone has already bought is refused here — unpublish it instead.</>}
          confirmLabel="Delete permanently"
          confirmPhrase="delete"
          pending={pending}
          onClose={() => setConfirming(false)}
          onConfirm={() => startTransition(async () => {
            const result = returnToList ? await deleteItemAndReturn(id) : await deleteItem(id);
            setConfirming(false);
            if (!result.ok) onError?.(result.error);
          })}
        />
      ) : null}
    </>
  );
}
