package org.mayabanque.wero.mock;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@Path("/sct-inst/transfers")
@RegisterRestClient(configKey="mock-sct-inst")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public interface SctInstClient {
    @POST
    WeroMockResource.TransferResponse transfer(WeroMockResource.TransferRequest request);
}
