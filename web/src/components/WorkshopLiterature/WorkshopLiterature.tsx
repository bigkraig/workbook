import React, {useEffect, useState} from "react";
import {GetWorkshopLiterature, IWorkshopLiterature} from "@/lib/api";
import {ToolsTable} from "@/app/ui/ToolsTable";
import {TechnicalValuesTable} from "@/app/ui/TechnicalValuesTable";
import {WorkshopChildren} from "@/components/WorkshopChildren";
import clsx from "clsx";
import {FileFormat} from "@/lib/api/types";
import {PDF} from "@/components/PDF";
import {PartsTable} from "@/app/ui/PartsTable";

export function WorkshopLiterature({hkap_id, translations}: { hkap_id: string, translations: Map<string, string> }) {
  let [workshopLiterature, setWorkshopLiterature] = useState<IWorkshopLiterature>()
  useEffect(() => {
    GetWorkshopLiterature(hkap_id).then(content => setWorkshopLiterature(content));
  }, [hkap_id])

  // A link can aim at a place in the document (#tool-AV8174); the content arrives
  // after the page does, so go there once it has rendered.
  useEffect(() => {
    if (!workshopLiterature || !window.location.hash) return;
    const id = decodeURIComponent(window.location.hash.slice(1));
    // Photos load lazily and change the page's height as they arrive, so keep
    // aiming until the target stays put, or the reader takes over.
    let steady = 0;
    const started = Date.now();
    const stop = () => clearInterval(timer);
    const timer = setInterval(() => {
      const el = document.getElementById(id);
      if (el) {
        // Scroll the window itself (scrollIntoView also shifts clipped ancestors),
        // leaving room for the fixed title bar.
        const before = el.getBoundingClientRect().top;
        window.scrollTo({top: before + window.scrollY - 72, behavior: "instant"});
        // Done once it has sat under the title bar for a couple of seconds; while the
        // page is still too short to scroll that far, keep waiting.
        steady = Math.abs(before - 72) < 2 ? steady + 1 : 0;
      }
      if (steady >= 8 || Date.now() - started > 10000) stop();
    }, 250);
    window.addEventListener("wheel", stop, {passive: true});
    window.addEventListener("touchmove", stop, {passive: true});
    window.addEventListener("keydown", stop);
    return () => {
      stop();
      window.removeEventListener("wheel", stop);
      window.removeEventListener("touchmove", stop);
      window.removeEventListener("keydown", stop);
    };
  }, [workshopLiterature])

  if (!workshopLiterature) {
    return <div></div>
  }

  return <div className={clsx("document-container", "mx-0 sm:mx-4", "bg-paper")}>
    {/*TEQ, 2602 from taycan*/}
    {/*<LaborOpsTable laborOps={data.laborops}/>*/}
    <PartsTable parts={workshopLiterature.parts} translations={translations}/>
    <ToolsTable tools={workshopLiterature.tools} translations={translations}/>
    <TechnicalValuesTable values={workshopLiterature.techvalues} translations={translations}/>
    <div className={clsx("mt-4")}/>
    {
      workshopLiterature.fileFormat == FileFormat.XML &&
        <WorkshopChildren obj={workshopLiterature.content} translations={translations}/>
    }
    {
      workshopLiterature.fileFormat == FileFormat.PDF &&
        <PDF id={workshopLiterature.mediaCloudFileId}/>
    }
  </div>
}